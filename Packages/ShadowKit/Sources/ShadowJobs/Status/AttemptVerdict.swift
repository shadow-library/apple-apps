import Foundation

public enum StandDownReason: Sendable, Hashable {
  case succeeded(AttemptID)
  case outranked(AttemptID)
}

/// Plan, Leases, stopping and resuming. An attempt started by hand never stands down for a live one. An automatic attempt stands down for another replica's
/// live attempt started by hand, whenever either started, and for an earlier live automatic one, so two automatic attempts that see each other agree on
/// which one goes on.
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
    } else if let leader = others.first(where: { $0.isLive(at: now) && attempt.yields(to: $0) }) {
      self = .standDown(.outranked(leader.id))
    } else {
      self = .proceed
    }
  }
}

extension AttemptRecord {
  /// Whether this attempt stands down while `other` is live: never when started by hand; for another replica's attempt started by hand, which never stands
  /// down itself, so the two would both write; otherwise when `other` outranks it.
  public func yields(to other: AttemptRecord) -> Bool {
    guard !start.byHand else { return false }
    return (other.start.byHand && other.start.replica != start.replica) || other.outranks(self)
  }
}
