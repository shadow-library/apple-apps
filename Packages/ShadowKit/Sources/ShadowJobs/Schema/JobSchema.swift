import ShadowStore

public enum JobSchema {
  public static let jobKind = makeKind("jobs_job")
  public static let attemptKind = makeKind("jobs_attempt")

  public static let entities: [EntitySchema] = [
    EntitySchema(
      kind: jobKind,
      shape: .record(fields: [
        JobField.request.rawValue: .firstWriterWins,
        JobField.cancel.rawValue: .monotone(order: JobCancel.allCases.map(\.rawValue)),
      ]),
      syncClass: .general
    ),
    EntitySchema(
      kind: attemptKind,
      shape: .record(fields: [
        AttemptField.start.rawValue: .firstWriterWins,
        AttemptField.lease.rawValue: .register,
        AttemptField.step.rawValue: .register,
        AttemptField.calls.rawValue: .register,
        AttemptField.outcome.rawValue: .monotone(order: AttemptOutcome.allCases.map(\.rawValue)),
        AttemptField.error.rawValue: .firstWriterWins,
      ]),
      syncClass: .general
    ),
  ]

  private static func makeKind(_ name: String) -> EntityKind {
    guard let kind = EntityKind(name) else { preconditionFailure("\(name) is a valid entity kind") }
    return kind
  }
}

public enum JobField: String, CaseIterable, Sendable {
  case request
  case cancel
}

// Written in one set when the job is requested; `origin` is an object the requesting app owns.
public enum JobRequestMember: String, CaseIterable, Sendable {
  case scope
  case kind
  case target
  case fingerprint
  case run
  case payload
  case origin
  case replica
}

public enum JobCancel: String, CaseIterable, Sendable {
  case none
  case requested
}

// Only the attempt's `start.replica` writes its lease, step, calls, outcome and error.
public enum AttemptField: String, CaseIterable, Sendable {
  case start
  case lease
  case step
  // Always the full cumulative list of the attempt's model call ids.
  case calls
  case outcome
  // Written only together with a `failed` outcome.
  case error
}

public enum AttemptStartMember: String, CaseIterable, Sendable {
  case job
  case replica
  case started
  case clock
  case byHand = "by_hand"
  case pinned
}

public enum AttemptClockSource: String, CaseIterable, Sendable {
  case trusted
  case device
}

public enum AttemptLeaseMember: String, CaseIterable, Sendable {
  case expires
  case renewed
  case clock
}

public enum AttemptStepMember: String, CaseIterable, Sendable {
  case name
  case index
}

// apps/novel-forge-server/src/modules/jobs/job.executor.ts:198-200 ranks a cancel over its abort error, as a stand-down is here; unlike :196, outputs outrank a cancel.
public enum AttemptOutcome: String, CaseIterable, Sendable {
  case running
  case failed
  case stoodDown = "stood_down"
  case cancelled
  case succeeded
}
