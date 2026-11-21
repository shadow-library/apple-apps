import ShadowCore
import ShadowJobs
import ShadowStore

/// How `JobEngine.interrupt(job:releasingLease:)` found the job's attempt on this device.
public enum JobInterruption: Sendable, Hashable {
  /// A run of it here stopped; `resumeHere(job:)` continues it from its checkpoint.
  case interrupted(AttemptID)
  /// No run of it was going here, but this device holds its checkpoint for `resumeHere(job:)`.
  case notRunning(AttemptID)
  /// It carries a stop mark (the job's cancel, a stand-down), so it settles at the next `settleStoppedAttempts()` or launch instead of resuming.
  case settling(AttemptID)
  /// This device holds no attempt of the job to resume: no attempt of the job is this device's, or its attempt here settled.
  case ended

  init(_ interruption: AttemptInterruption, attempt: AttemptID) {
    switch interruption {
    case .interrupted: self = .interrupted(attempt)
    case .notRunning: self = .notRunning(attempt)
    case .settling: self = .settling(attempt)
    case .ended: self = .ended
    }
  }

  private var rank: Int {
    switch self {
    case .interrupted: 3
    case .settling: 2
    case .notRunning: 1
    case .ended: 0
    }
  }

  func outranked(by other: JobInterruption) -> JobInterruption {
    other.rank > rank ? other : self
  }
}

/// A run this device stopped and can resume with `JobEngine.resumeHere(job:)`; `step` is the one it continues from.
public struct InterruptedJobRun: Sendable, Hashable {
  public let attempt: AttemptID
  public let job: EntityRef
  public let target: NovelJobTarget
  public let step: AttemptStep

  public init(attempt: AttemptID, job: EntityRef, target: NovelJobTarget, step: AttemptStep) {
    self.attempt = attempt
    self.job = job
    self.target = target
    self.step = step
  }
}
