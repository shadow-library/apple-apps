import ShadowCore
import ShadowStore

public enum JobRunError: ShadowError {
  case record(JobRecordError)
  case store(StoreError)
  case unknownStep(String)
  case jobUnreadable(EntityRef)
  case jobCancelled(EntityRef)
  case jobSucceeded(EntityRef)
  case anotherAttemptLive(AttemptID)
  case alreadyRunningHere(AttemptID)
  /// The attempt's checkpoint here is no longer the one its step ran from: another process on this vault drove the attempt on.
  case checkpointMoved(AttemptID)
  case interrupted

  public var code: String {
    switch self {
    case .record(let error): error.code
    case .store(let error): error.code
    case .unknownStep: "job_run.unknown_step"
    case .jobUnreadable: "job_run.job_unreadable"
    case .jobCancelled: "job_run.job_cancelled"
    case .jobSucceeded: "job_run.job_succeeded"
    case .anotherAttemptLive: "job_run.another_attempt_live"
    case .alreadyRunningHere: "job_run.already_running_here"
    case .checkpointMoved: "job_run.checkpoint_moved"
    case .interrupted: "job_run.interrupted"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .record(let error): error.errorDescription
    case .store(let error): error.errorDescription
    case .unknownStep(let name): "The pipeline has no step named \(name)."
    case .jobUnreadable(let ref): "Job \(ref.key) has not arrived or cannot be read."
    case .jobCancelled(let ref): "Job \(ref.key) was cancelled."
    case .jobSucceeded(let ref): "Job \(ref.key) already succeeded."
    case .anotherAttemptLive(let attempt): "Attempt \(attempt.uuid.lowercasedString) is running the job with a live lease."
    case .alreadyRunningHere(let attempt): "This device is already running the job as attempt \(attempt.uuid.lowercasedString)."
    case .checkpointMoved(let attempt): "Attempt \(attempt.uuid.lowercasedString) moved past this step in another process."
    case .interrupted: "The attempt stopped as a crash stops it."
    }
  }

  init(_ error: any Error) {
    switch Self.unwrapped(error) {
    case let error as JobRunError: self = error
    case let error as JobRecordError: self = .record(error)
    case let error as StoreError: self = .store(error)
    case let error: self = .store(.aborted(error))
    }
  }

  var underlying: any Error {
    guard case .store(.aborted(let inner)) = self else { return self }
    return Self.unwrapped(inner)
  }

  /// A write body's error reaches the caller as `StoreError.aborted`.
  static func unwrapped(_ error: any Error) -> any Error {
    guard case StoreError.aborted(let inner) = error else { return error }
    return unwrapped(inner)
  }
}
