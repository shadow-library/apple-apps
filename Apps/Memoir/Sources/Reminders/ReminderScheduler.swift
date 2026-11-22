import Foundation
import MemoirCore
import OSLog
import Observation
import ShadowAppShell
import ShadowCore

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Keeps this device's pending notification requests equal to the open vault's `ReminderPlan` while "Remind me on this device" is on, and withdraws
/// them all when it is turned off. A completion or deletion, here or synced from another device, changes the plan, which withdraws its request, and
/// one that has already fired is removed from those shown while its occurrence is among the plan's `settled`. Only requests under
/// `Reminder.identifierPrefix` are ever removed.
@Observable
final class ReminderScheduler {
  /// Headroom under the system's 64 pending requests, which drops the rest silently.
  static let planLimit = ReminderQuery.systemPendingLimit - 4

  nonisolated private static var logger: Logger { Logger(subsystem: AppIdentity.memoir.id, category: "reminders") }

  nonisolated static var activations: [Notification.Name] {
    #if os(macOS)
      [NSApplication.didBecomeActiveNotification]
    #else
      [UIApplication.didBecomeActiveNotification]
    #endif
  }

  private(set) var isOnThisDevice: Bool
  private(set) var authorization: ReminderAuthorization?
  /// Replay halted at a command this build cannot read, so the plan holds no quest reminders until Memoir is updated.
  private(set) var questsPaused = false
  private(set) var omitted = 0
  private(set) var upcoming = 0

  @ObservationIgnored private let notifications: any ReminderNotifications
  @ObservationIgnored private let setting: ReminderDeviceSetting
  @ObservationIgnored private let limit: Int
  @ObservationIgnored private let center: NotificationCenter
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []
  @ObservationIgnored private var vault: MemoirOpenedVault?
  @ObservationIgnored private var observing: Task<Void, Never>?
  @ObservationIgnored private var latest: ReminderPlan?
  @ObservationIgnored private var queue: Task<Void, Never>?
  @ObservationIgnored private var isReconcileQueued = false

  /// `restartOn` builds the plan again: a wait under way does not notice the clock or the device's zone changing, and the device's zone governs
  /// until the account has one. A return to the foreground restarts too, which also reads a permission changed in Settings meanwhile.
  init(
    notifications: any ReminderNotifications, setting: ReminderDeviceSetting, limit: Int = planLimit, center: NotificationCenter = .default,
    restartOn: [Notification.Name] = MemoirDayTurns.clockChanges + activations
  ) {
    self.notifications = notifications
    self.setting = setting
    self.limit = limit
    self.center = center
    isOnThisDevice = setting.isOn
    observers = restartOn.map { name in
      center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in Task { @MainActor in self?.restart() } }
    }
  }

  isolated deinit {
    observing?.cancel()
    for observer in observers { center.removeObserver(observer) }
  }

  static func live() -> ReminderScheduler {
    let notifications: any ReminderNotifications = MemoirVaultOpener.isHostedByTests ? InertReminderNotifications() : SystemReminderNotifications()
    return ReminderScheduler(notifications: notifications, setting: ReminderDeviceSetting())
  }

  /// Starts following `opened`, keeps following a vault already followed, and stops when there is none. A closed vault leaves its requests pending:
  /// a device locked since it restarted cannot open the vault, and its reminders still fire.
  func follow(_ opened: MemoirOpenedVault?) {
    guard let opened else { return stop() }
    if let vault, vault.stores.main === opened.stores.main { return }
    vault = opened
    restart()
  }

  func stop() {
    observing?.cancel()
    observing = nil
    latest = nil
    vault = nil
    questsPaused = false
    omitted = 0
    upcoming = 0
  }

  /// Stops following the vault and removes every reminder it scheduled on this device, delivered ones included, whatever the device setting says.
  func withdrawAll() {
    stop()
    enqueue { [weak self] in await self?.withdraw(delivered: true) }
  }

  func setOnThisDevice(_ isOn: Bool) {
    guard isOn != isOnThisDevice else { return }
    setting.set(isOn)
    isOnThisDevice = isOn
    restart()
  }

  func refreshAuthorization() async {
    authorization = await notifications.authorization()
  }

  func restart() {
    observing?.cancel()
    observing = nil
    latest = nil
    guard isOnThisDevice else { return enqueueReconcile() }
    guard let vault else { return }
    let query: ReminderQuery
    do throws(ReminderQueryError) {
      query = try ReminderQuery(limit: limit, device: vault.clock.deviceZone())
    } catch {
      return Self.log("The reminder query was refused", error)
    }
    let plans = ReminderReads.observePlan(in: vault.stores, query: query, now: vault.clock.now, waitUntil: vault.clock.waitUntil)
    observing = Task { [weak self] in
      do {
        for try await plan in plans {
          guard !Task.isCancelled else { return }
          self?.received(plan)
        }
      } catch {
        guard !Task.isCancelled else { return }
        Self.log("The reminder plan stopped", error)
      }
    }
  }

  private func received(_ plan: ReminderPlan) {
    latest = plan
    questsPaused = plan.halt != nil
    omitted = plan.omitted
    upcoming = plan.reminders.count
    enqueueReconcile()
  }

  /// One reconcile at a time, each reading the latest plan and setting when it runs, so a burst of plans or a toggle mid-way is applied once.
  private func enqueueReconcile() {
    guard !isReconcileQueued else { return }
    isReconcileQueued = true
    enqueue { [weak self] in
      guard let self else { return }
      isReconcileQueued = false
      await reconcile()
    }
  }

  private func enqueue(_ work: @escaping @MainActor () async -> Void) {
    let previous = queue
    queue = Task {
      await previous?.value
      await work()
    }
  }

  private func withdraw(delivered: Bool) async {
    let pending = Self.ours(await notifications.pendingIdentifiers())
    if !pending.isEmpty { notifications.remove(pending) }
    guard delivered else { return }
    let shown = Self.ours(Set(await notifications.delivered().map(\.identifier)))
    if !shown.isEmpty { notifications.removeDelivered(shown) }
  }

  private static func ours(_ identifiers: Set<String>) -> [String] {
    identifiers.filter { $0.hasPrefix(Reminder.identifierPrefix) }.sorted()
  }

  /// Our shown reminders whose occurrence the plan names as settled.
  static func settled(_ delivered: [DeliveredReminder], in plan: ReminderPlan) -> [String] {
    delivered.filter { reminder in
      guard reminder.identifier.hasPrefix(Reminder.identifierPrefix), let occurrence = ReminderCopy.occurrence(in: reminder.userInfo) else { return false }
      return plan.settled.contains(occurrence)
    }.map(\.identifier).sorted()
  }

  private func reconcile() async {
    guard isOnThisDevice else { return await withdraw(delivered: false) }
    let pending = await notifications.pendingIdentifiers()
    guard let plan = latest else { return await refreshAuthorization() }
    authorization = plan.reminders.isEmpty ? await notifications.authorization() : await authorize()
    let diff = plan.diff(against: pending)
    if !diff.remove.isEmpty { notifications.remove(diff.remove) }
    if !plan.settled.isEmpty {
      let shown = Self.settled(await notifications.delivered(), in: plan)
      if !shown.isEmpty { notifications.removeDelivered(shown) }
    }
    guard authorization == .allowed else { return }
    for reminder in diff.add {
      guard isOnThisDevice, latest == plan else { return }
      do throws(ReminderNotificationError) {
        try await notifications.add(ReminderCopy.request(for: reminder))
      } catch {
        Self.log("A reminder was not scheduled", error)
      }
    }
  }

  /// Asked only once there is a reminder to deliver, so the system's prompt explains itself.
  private func authorize() async -> ReminderAuthorization {
    let status = await notifications.authorization()
    guard status == .notDetermined else { return status }
    do throws(ReminderNotificationError) {
      _ = try await notifications.requestAuthorization()
    } catch {
      Self.log("The notification permission request failed", error)
    }
    return await notifications.authorization()
  }

  nonisolated private static func log(_ message: StaticString, _ error: any Error) {
    let code = (error as? any ShadowError)?.code ?? "unknown"
    logger.error("\(String(describing: message), privacy: .public) code=\(code, privacy: .public)")
  }
}
