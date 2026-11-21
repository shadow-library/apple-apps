import Foundation
import NovelForgeCore

/// What `BGContinuedProcessingTaskRequest` is made from; always submitted with the `.fail` strategy, so it runs at once or is refused.
nonisolated struct ContinuedProcessingRequest: Equatable, Sendable {
  let identifier: String
  let title: String
  let subtitle: String
}

/// Why the system refused a continued-processing request (`BGTaskScheduler.Error`).
nonisolated enum ContinuedProcessingRefusal: Error, Equatable, Sendable {
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
nonisolated struct ContinuedProcessingUnits: Equatable, Sendable {
  var completed: Int64 = 0
  var total: Int64 = 1

  /// Output tokens received of those expected; the expected count shrinks as calls finish short of their cap, so it is held at no less than what arrived.
  func advanced(by progress: JobRunProgress) -> ContinuedProcessingUnits {
    let completed = max(completed, Int64(max(0, progress.tokensReceived)))
    return ContinuedProcessingUnits(completed: completed, total: max(Int64(progress.tokensExpected), completed, 1))
  }

  var finished: ContinuedProcessingUnits {
    ContinuedProcessingUnits(completed: total, total: total)
  }
}

/// A started `BGContinuedProcessingTask`.
protocol ContinuedProcessingTask: AnyObject {
  var identifier: String { get }
  /// Called for the system's expiry and for the person's cancel in the system UI alike.
  func onExpiration(_ handler: @escaping @MainActor () -> Void)
  func report(_ units: ContinuedProcessingUnits)
  func update(title: String, subtitle: String)
  func complete(success: Bool)
}

/// `BGTaskScheduler` for continued processing.
protocol ContinuedProcessingScheduler: AnyObject {
  /// One launch handler for every identifier under `wildcard`; a second registration of the same wildcard replaces the handler.
  func register(_ wildcard: String, launch: @escaping @MainActor (any ContinuedProcessingTask) -> Void)
  func submit(_ request: ContinuedProcessingRequest) async throws(ContinuedProcessingRefusal)
}
