import Foundation

public enum StandDownReason: Sendable, Hashable {
  case succeeded(AttemptID)
  case outranked(AttemptID)
}

/// Plan, Leases, stopping and resuming; rank order makes two automatic attempts that see each other live agree on which one goes on.
public enum AttemptVerdict: Sendable, Hashable {
  case proceed
  case cancel
  case standDown(StandDownReason)

  public init(for attempt: AttemptRecord, in snapshot: JobSnapshot, at now: LeaseInstant) {
    let others = snapshot.attempts.filter { $0.id != attempt.id }
    if let succeeded = others.first(where: { $0.outcome == .succeeded }) {
      self = .standDown(.succeeded(succeeded.id))
    } else if snapshot.job.cancel == .requested || others.contains(where: { $0.outcome == .cancelled }) {
      self = .cancel
    } else if !attempt.start.byHand, let leader = others.first(where: { $0.isLive(at: now) && $0.outranks(attempt) }) {
      self = .standDown(.outranked(leader.id))
    } else {
      self = .proceed
    }
  }
}
