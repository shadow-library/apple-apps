import ShadowAppShell

#if os(macOS)
  import Foundation
  import NovelForgeCore
  import OSLog
  import Observation
  import ShadowCore
  import ShadowJobs
  import ShadowStore

  /// Whether Novel Forge opens at login, as the system last answered, or why it refused.
  enum LoginItemState: Equatable {
    case status(LoginItemStatus)
    case refused(LoginItemError)
  }

  /// Worker mode on this Mac (phase 8 decision 4). Turning it on names this replica the open vault's worker through the vault's `JobEngine`, keeps sync in
  /// front and the Mac out of App Nap with no window open, shows the menu-bar item and only then asks the system to open the app at login; turning it off
  /// names no worker only while the record still names this Mac, and takes the login item away. Turned off while no engine can write the record (the
  /// library did not open, or another copy holds its jobs), it stops here at once and clears the record when a vault is next attached. The record is the truth the job runtime drains by: another
  /// Mac named after this one, or the record naming none, turns worker mode off here, and a record naming this Mac turns it on without touching the login
  /// item. The preference is per device and remembers the replica it was turned on as, so a library opened in place of that one is never named on its own.
  @MainActor
  @Observable
  final class WorkerModel {
    enum Change: Equatable {
      case turningOn
      case turningOff
    }

    enum Notice: Equatable {
      /// Another Mac was named the worker after this one; nil while the replica directory has no name for it.
      case takenOver(by: String?)
      /// The record names no Mac any more, as when another Mac took over and later turned worker mode off.
      case stoppedElsewhere
      /// The library open now is not the one worker mode was turned on for.
      case libraryChanged
    }

    struct Effects {
      var keepSyncInFront: @MainActor (Bool) async -> Void
      /// Held while worker mode is on: keeps a Mac with no window out of App Nap, so polls and lease renewals keep their times; idle sleep stays allowed.
      var presence: JobPowerAssertion
    }

    nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.novelforge", category: "worker")

    private(set) var isOn: Bool
    /// The open vault's worker as this Mac last read it; nil while no vault's jobs run in this copy of the app.
    private(set) var worker: VaultWorker?
    /// Whether the open vault's worker record can be written from here.
    private(set) var canDesignate = false
    private(set) var change: Change?
    private(set) var loginItem: LoginItemState
    private(set) var notice: Notice?
    var failure: PresentedError?
    /// The open vault's job runtime, which the menu's status reads.
    private(set) var runtime: JobRuntime?
    private(set) var currentRun: WorkerRun?

    @ObservationIgnored private let preference: WorkerPreference
    @ObservationIgnored private let login: any LoginItem
    @ObservationIgnored private let effects: Effects
    @ObservationIgnored private var access: (any WorkerRecordAccess)?
    @ObservationIgnored private var observing: Task<Void, Never>?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var watching: Task<Void, Never>?

    init(preference: WorkerPreference, loginItem: any LoginItem, effects: Effects) {
      self.preference = preference
      login = loginItem
      self.effects = effects
      isOn = preference.replica != nil
      self.loginItem = .status(loginItem.status)
    }

    static func live(sync: SyncRuntimes) -> WorkerModel {
      guard !VaultDirectory.isHostedByTests else {
        let suite = "com.shadow.apps.novelforge.tests.worker-host"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkerModel(
          preference: WorkerPreference(defaults: defaults), loginItem: InertLoginItem(),
          effects: Effects(keepSyncInFront: { _ in }, presence: JobPowerAssertion(activity: JobPowerAssertion.Activity(begin: { nil }, end: { _ in }))))
      }
      let presence = JobPowerAssertion(
        activity: JobPowerAssertion.Activity(
          begin: { ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Novel Forge runs this library's jobs") },
          end: { ProcessInfo.processInfo.endActivity($0) }))
      return WorkerModel(
        preference: WorkerPreference(defaults: .standard), loginItem: SystemLoginItem(),
        effects: Effects(keepSyncInFront: { [weak sync] kept in await sync?.keepInFront(kept) }, presence: presence))
    }

    var status: WorkerMenuStatus {
      WorkerMenuStatus(
        mode: runtime?.mode, consentNeeded: runtime?.consentNeeded != nil, runs: runtime?.runsHere.count ?? 0, run: currentRun, worker: worker)
    }

    /// At launch, before any window: worker mode turned on before keeps sync in front and the Mac out of App Nap again. The login item is left as it is.
    func launched() async {
      guard isOn else { return }
      await apply(on: true)
    }

    /// Follows the open vault's job runtime: its engine, once it runs jobs here, is where the worker record is read and written.
    func follow(_ jobs: JobRuntimes) {
      following?.cancel()
      let states = Observations { () -> Followed in
        let runtime = jobs.active
        let engine = runtime?.runsJobs == true ? runtime?.engine : nil
        let access = engine.flatMap { engine in runtime.map { EngineWorkerAccess(engine: engine, replica: $0.store.replica) } }
        return Followed(runtime: runtime, access: access, firstRun: runtime?.runsHere.first)
      }
      following = Task { [weak self] in
        for await state in states {
          guard let self, !Task.isCancelled else { return }
          self.runtime = state.runtime
          self.attach(state.access)
          self.watch(state.firstRun, of: state.runtime)
        }
      }
    }

    func attach(_ access: (any WorkerRecordAccess)?) {
      guard access?.identity != self.access?.identity else { return }
      observing?.cancel()
      self.access = access
      worker = nil
      canDesignate = access != nil
      guard let access else { return }
      let updates = access.observeWorker()
      observing = Task { [weak self] in
        do {
          for try await worker in updates {
            guard let self, !Task.isCancelled else { return }
            await self.reflect(worker, from: access)
          }
        } catch is CancellationError {
          return
        } catch {
          Self.logger.error("Stopped following the vault's worker")
        }
      }
    }

    func turnOn() async {
      guard let access, change == nil else { return }
      change = .turningOn
      defer { change = nil }
      notice = nil
      do throws(JobEngineError) {
        worker = try await access.designate(.thisReplica)
      } catch {
        failure = Self.failure(error)
        return
      }
      preference.saveClearPending(nil)
      preference.save(access.replica)
      isOn = true
      registerLoginItem()
      await apply(on: true)
    }

    func turnOff() async {
      guard change == nil, access != nil || isOn else { return }
      change = .turningOff
      defer { change = nil }
      notice = nil
      guard let access else {
        preference.saveClearPending(preference.replica)
        return await turnedOff()
      }
      do throws(JobEngineError) {
        let current = try await access.worker()
        worker = current.isHere ? try await access.designate(.none) : current
      } catch {
        failure = Self.failure(error)
        return
      }
      await turnedOff()
    }

    /// Asked for by the user only: turning worker mode on, or Open at Login after the item was taken away in System Settings.
    func registerLoginItem() {
      do throws(LoginItemError) {
        try login.register()
        loginItem = .status(login.status)
      } catch {
        Self.logger.error("Novel Forge could not be added to the login items code=\(error.code, privacy: .public)")
        loginItem = .refused(error)
      }
    }

    func openLoginItemsSettings() {
      login.openSystemSettingsLoginItems()
    }

    /// After the user may have changed it in System Settings; a refusal stays until the system answers something other than not registered.
    func refreshLoginItem() {
      let status = login.status
      if case .refused = loginItem, status == .notRegistered { return }
      loginItem = .status(status)
    }

    func dismissNotice() {
      notice = nil
    }

    /// An emission may predate this Mac's own last designation, so the record is read again before worker mode follows it on or off.
    private func reflect(_ observed: VaultWorker, from access: any WorkerRecordAccess) async {
      guard self.access?.identity == access.identity else { return }
      worker = observed
      guard change == nil else { return }
      if preference.clearPending != nil { return await clearPending(observed, from: access) }
      guard unsettled(by: observed, as: access.replica) else { return }
      let confirmed: VaultWorker
      do throws(JobEngineError) {
        confirmed = try await access.worker()
      } catch {
        Self.logger.error("The vault's worker could not be read again code=\(error.code, privacy: .public)")
        return
      }
      guard self.access?.identity == access.identity, change == nil else { return }
      worker = confirmed
      guard unsettled(by: confirmed, as: access.replica) else { return }
      if confirmed.isHere {
        await adopt(access)
      } else if preference.replica != access.replica {
        await stop(.libraryChanged)
      } else if case .named(let device) = confirmed {
        await stop(.takenOver(by: device.name))
      } else {
        await stop(.stoppedElsewhere)
      }
    }

    /// Worker mode was turned off while the record could not be written: a record still naming this Mac is cleared now, and nothing turns worker mode back
    /// on until it is. The marker stays when the write fails, for the next emission or attach.
    private func clearPending(_ observed: VaultWorker, from access: any WorkerRecordAccess) async {
      change = .turningOff
      defer { change = nil }
      do throws(JobEngineError) {
        let current = observed.isHere ? try await access.worker() : observed
        worker = current.isHere ? try await access.designate(.none) : current
      } catch {
        Self.logger.error("The vault's worker could not be cleared code=\(error.code, privacy: .public)")
        return
      }
      guard self.access?.identity == access.identity else { return }
      if case .unreadable = worker { return }
      preference.saveClearPending(nil)
    }

    /// Whether worker mode disagrees with the record: one naming this Mac while it is off, or under a replica it was not turned on as; one naming another
    /// Mac, or none, while it is on. An unreadable record changes nothing.
    private func unsettled(by worker: VaultWorker, as replica: ReplicaID) -> Bool {
      if worker.isHere { return !isOn || preference.replica != replica }
      if case .unreadable = worker { return false }
      return isOn
    }

    /// The record names this Mac, as after a retired replica's successor took its place or this Mac's defaults were lost: worker mode follows it, and the
    /// login item stays as it is.
    private func adopt(_ access: any WorkerRecordAccess) async {
      preference.save(access.replica)
      guard !isOn else { return }
      isOn = true
      await apply(on: true)
    }

    private func stop(_ notice: Notice) async {
      Self.logger.notice("Worker mode turned off: the vault's worker record no longer names this Mac")
      self.notice = notice
      await turnedOff()
    }

    private func turnedOff() async {
      preference.save(nil)
      isOn = false
      do throws(LoginItemError) {
        try login.unregister()
      } catch {
        Self.logger.error("Novel Forge could not be taken out of the login items code=\(error.code, privacy: .public)")
      }
      refreshLoginItem()
      await apply(on: false)
    }

    private func apply(on: Bool) async {
      if on, !effects.presence.isHeld {
        effects.presence.begin()
      } else if !on {
        effects.presence.release()
      }
      await effects.keepSyncInFront(on)
    }

    private func watch(_ run: JobRunHere?, of runtime: JobRuntime?) {
      guard run != currentRun?.run else { return }
      watching?.cancel()
      guard let run, let runtime else {
        currentRun = nil
        return
      }
      currentRun = WorkerRun(run: run)
      let (store, progress) = (runtime.store, runtime.observeRun(run.attempt))
      watching = Task { [weak self] in
        let kind = await Self.kind(of: run.job, in: store)
        guard let self, !Task.isCancelled, self.currentRun?.run == run else { return }
        self.currentRun?.kind = kind
        for await update in progress {
          guard !Task.isCancelled, self.currentRun?.run == run else { return }
          self.currentRun?.progress = update
        }
      }
    }

    nonisolated private static func kind(of job: EntityRef, in store: VaultStore) async -> NovelJobKind? {
      let record = try? await store.read { transaction in try JobRecords.read(job, in: transaction).record }
      return record.flatMap { NovelJobKind(rawValue: $0.request.key.kind) }
    }

    private static func failure(_ error: JobEngineError) -> PresentedError {
      PresentedError(headline: String(localized: "The Mac that runs jobs could not be changed.", table: "Worker"), detail: error.code)
    }
  }

  private struct Followed: Sendable {
    let runtime: JobRuntime?
    let access: EngineWorkerAccess?
    let firstRun: JobRunHere?
  }
#endif
