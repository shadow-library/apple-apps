import Foundation
import ShadowCore
import UserNotifications

nonisolated enum ReminderAuthorization: Sendable, Hashable {
  case notDetermined
  case denied
  case allowed
}

/// A notification the system has shown and still lists, with the string values of its request's `userInfo`.
nonisolated struct DeliveredReminder: Sendable, Hashable {
  let identifier: String
  let userInfo: [String: String]
}

/// One local notification as the scheduler asks for it, already in the owner's words.
nonisolated struct ReminderRequest: Sendable, Hashable {
  let identifier: String
  let title: String
  let body: String
  let fireAt: Date
  let thread: String
  let userInfo: [String: String]
}

nonisolated struct ReminderNotificationError: ShadowError, Equatable {
  enum Operation: Sendable, Equatable {
    case add
    case authorization
  }

  let operation: Operation
  let domain: String
  let number: Int

  init(_ operation: Operation, _ error: any Error) {
    let error = error as NSError
    self.operation = operation
    domain = error.domain
    number = error.code
  }

  var code: String {
    switch operation {
    case .add: "memoir_reminders.add_refused"
    case .authorization: "memoir_reminders.authorization_failed"
    }
  }

  var errorDescription: String? {
    switch operation {
    case .add: "The system refused a reminder (\(domain) \(number))."
    case .authorization: "The system could not ask for permission to notify (\(domain) \(number))."
    }
  }
}

/// The app's pending and delivered local notifications and its permission to show them.
@MainActor
protocol ReminderNotifications: AnyObject {
  func pendingIdentifiers() async -> Set<String>
  func add(_ request: ReminderRequest) async throws(ReminderNotificationError)
  func remove(_ identifiers: [String])
  func delivered() async -> [DeliveredReminder]
  func removeDelivered(_ identifiers: [String])
  func authorization() async -> ReminderAuthorization
  func requestAuthorization() async throws(ReminderNotificationError) -> Bool
}

final class SystemReminderNotifications: ReminderNotifications {
  private let center: UNUserNotificationCenter
  private let presenter = ForegroundPresenter()

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
    center.delegate = presenter
  }

  func pendingIdentifiers() async -> Set<String> {
    Set(await center.pendingNotificationRequests().map(\.identifier))
  }

  func add(_ request: ReminderRequest) async throws(ReminderNotificationError) {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.sound = .default
    content.threadIdentifier = request.thread
    content.userInfo = request.userInfo
    do {
      try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: Self.trigger(at: request.fireAt)))
    } catch {
      throw ReminderNotificationError(.add, error)
    }
  }

  func remove(_ identifiers: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  func delivered() async -> [DeliveredReminder] {
    await center.deliveredNotifications().map { notification in
      let request = notification.request
      let values = request.content.userInfo.compactMap { key, value -> (String, String)? in
        guard let key = key as? String, let value = value as? String else { return nil }
        return (key, value)
      }
      return DeliveredReminder(identifier: request.identifier, userInfo: Dictionary(values) { first, _ in first })
    }
  }

  func removeDelivered(_ identifiers: [String]) {
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
  }

  func authorization() async -> ReminderAuthorization {
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined: .notDetermined
    case .authorized, .provisional, .ephemeral: .allowed
    case .denied: .denied
    @unknown default: .denied
    }
  }

  func requestAuthorization() async throws(ReminderNotificationError) -> Bool {
    do {
      return try await center.requestAuthorization(options: [.alert, .sound])
    } catch {
      throw ReminderNotificationError(.authorization, error)
    }
  }

  /// A calendar trigger matches its components in the device's current zone unless they carry their own, so the instant is pinned to a zone: a
  /// floating time would move with the device's zone while the request keeps the identifier of its original instant.
  nonisolated static func trigger(at date: Date, pinnedTo zone: TimeZone = .gmt) -> UNCalendarNotificationTrigger {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    components.calendar = calendar
    components.timeZone = zone
    return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
  }
}

/// Without a delegate the system drops a notification that arrives while the app is in front; tapping one opens the app.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }
}

/// While XCTest hosts the app: the notification center of the device running the tests is never read or changed.
final class InertReminderNotifications: ReminderNotifications {
  func pendingIdentifiers() async -> Set<String> { [] }

  func add(_ request: ReminderRequest) async throws(ReminderNotificationError) {}

  func remove(_ identifiers: [String]) {}

  func delivered() async -> [DeliveredReminder] { [] }

  func removeDelivered(_ identifiers: [String]) {}

  func authorization() async -> ReminderAuthorization { .notDetermined }

  func requestAuthorization() async throws(ReminderNotificationError) -> Bool { false }
}
