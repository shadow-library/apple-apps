import Foundation

public enum JobPhase: String, CaseIterable, Sendable {
  case queued
  case running
  case failed
  case cancelled
  case succeeded
}

/// An attempt ended cancelled counts as the cancel, which may not have arrived; a lapsed attempt with no outcome leaves the job queued, to be run again.
public enum JobStatus: Sendable, Hashable {
  case queued
  case running(AttemptID)
  case failed(AttemptID, AttemptFailure?)
  case cancelled
  case succeeded(AttemptID)

  public var phase: JobPhase {
    switch self {
    case .queued: .queued
    case .running: .running
    case .failed: .failed
    case .cancelled: .cancelled
    case .succeeded: .succeeded
    }
  }

  public init(_ snapshot: JobSnapshot, at now: LeaseInstant) {
    let attempts = snapshot.attempts
    if let succeeded = attempts.first(where: { $0.outcome == .succeeded }) {
      self = .succeeded(succeeded.id)
    } else if snapshot.job.cancel == .requested || attempts.contains(where: { $0.outcome == .cancelled }) {
      self = .cancelled
    } else if let live = attempts.first(where: { $0.isLive(at: now) }) {
      self = .running(live.id)
    } else if let latest = attempts.last(where: { $0.outcome != .stoodDown }), latest.outcome == .failed {
      self = .failed(latest.id, latest.error)
    } else {
      self = .queued
    }
  }
}
