import Foundation

/// What `BGContinuedProcessingTaskRequest` is made from; always submitted with the `.fail` strategy, so it runs at once or is refused.
public nonisolated struct ContinuedProcessingRequest: Equatable, Sendable {
  public let identifier: String
  public let title: String
  public let subtitle: String

  public init(identifier: String, title: String, subtitle: String) {
    self.identifier = identifier
    self.title = title
    self.subtitle = subtitle
  }
}

/// Why the system refused a continued-processing request (`BGTaskScheduler.Error`).
public nonisolated enum ContinuedProcessingRefusal: Error, Equatable, Sendable {
  /// The system could not start it at once.
  case ineligible
  /// This device runs no background work, as on the Simulator or with Background App Refresh off.
  case unavailable
  /// The identifier is not permitted by the Info.plist, or the person denied the app background launches.
  case notPermitted
  case tooManyPending
  case unknown(code: Int)
}

/// The task's progress as the system shows it: `completed` never falls and never passes `total`, which is at least 1.
public nonisolated struct ContinuedProcessingUnits: Equatable, Sendable {
  public var completed: Int64 = 0
  public var total: Int64 = 1

  public init(completed: Int64 = 0, total: Int64 = 1) {
    self.completed = completed
    self.total = total
  }

  public var finished: ContinuedProcessingUnits {
    ContinuedProcessingUnits(completed: total, total: total)
  }
}

/// A started `BGContinuedProcessingTask`.
public protocol ContinuedProcessingTask: AnyObject {
  var identifier: String { get }
  /// Called for the system's expiry and for the person's cancel in the system UI alike.
  func onExpiration(_ handler: @escaping @MainActor () -> Void)
  func report(_ units: ContinuedProcessingUnits)
  func update(title: String, subtitle: String)
  func complete(success: Bool)
}

/// `BGTaskScheduler` for continued processing.
public protocol ContinuedProcessingScheduler: AnyObject {
  /// One launch handler for every identifier under `wildcard`; a second registration of the same wildcard replaces the handler.
  func register(_ wildcard: String, launch: @escaping @MainActor (any ContinuedProcessingTask) -> Void)
  func submit(_ request: ContinuedProcessingRequest) async throws(ContinuedProcessingRefusal)
}
