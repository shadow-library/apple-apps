import Foundation
import ShadowCore
import ShadowStore

/// A cancelled step (the job's cancel, a stand-down) should end its in-flight call; one that finishes anyway has its output kept.
public protocol PipelineStep: Sendable {
  func run(_ input: JSONValue, in context: AttemptStepContext) async throws -> AttemptStepOutput
}

public struct AttemptStepOutput: Sendable {
  public let state: JSONValue
  /// The step to run next; nil ends the attempt as succeeded in the same transaction.
  public let next: String?
  public let writes: @Sendable (inout WriteTransaction) throws -> Void

  public init(state: JSONValue, next: String?, writes: @escaping @Sendable (inout WriteTransaction) throws -> Void = { _ in }) {
    self.state = state
    self.next = next
    self.writes = writes
  }
}

public struct AttemptPipeline: Sendable {
  public let first: String
  public let steps: [String: any PipelineStep]

  public init(first: String, steps: [String: any PipelineStep]) {
    self.first = first
    self.steps = steps
  }
}

public struct AttemptStepContext: Sendable {
  public let attempt: AttemptID
  public let job: JobRecord
  public let start: AttemptStart
  public let step: AttemptStep
  let control: AttemptControl
  let opened: @Sendable () -> Void

  public var isStopping: Bool { control.stop != nil || control.isCrashed }

  /// Joins the transaction that opens a ledger call.
  public func recordCall(_ call: UUID, in transaction: inout WriteTransaction) throws(JobRecordError) {
    try AttemptRecords.recordCall(call, attempt: attempt, by: start.replica, in: &transaction)
    opened()
  }
}
