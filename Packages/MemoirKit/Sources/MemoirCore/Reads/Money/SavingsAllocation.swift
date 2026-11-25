import Foundation

/// A goal's part of savings, in the home currency.
public struct GoalShare: Sendable, Hashable, Identifiable {
  public let goal: SavingsGoalRecord
  /// What savings hold for the goal now; zero once it is bought or abandoned.
  public let shareMinor: Int64
  /// What the expenses naming the goal drew on savings, those still waiting for a rate left out.
  public let drawnMinor: Int64
  /// What the pool held for the goal before its own draws came out of it, at most the target: never money borrowed below zero. Zero once the goal is
  /// bought or abandoned.
  public let heldMinor: Int64

  public var id: UUID { goal.id }

  /// What the goal has gathered: what savings hold for it and what its purchases already drew from it, at most the target. Milestones and progress read
  /// this, so buying part of a goal never moves it backwards.
  public var filledMinor: Int64 { Int64(clamping: min(Int128(goal.targetMinor), Int128(max(0, shareMinor)) + Int128(max(0, drawnMinor)))) }

  /// What the goal still needs, never below zero: a lowered target, or a purchase beside a full share, can leave it at zero.
  public var remainingMinor: Int64 { max(0, goal.targetMinor - filledMinor) }

  /// `filledMinor` against the target, in thousandths rounded down and at most 1000.
  public var progressThousandths: Int {
    thousandths(of: filledMinor)
  }

  /// What savings really gathered for the goal against its target, in thousandths rounded down: `filledMinor`, but no more than the pool held for it
  /// (`heldMinor`), so a purchase that borrowed below zero or drew beyond the goal's share earns no milestone for that part.
  public var savedThousandths: Int {
    thousandths(of: min(filledMinor, heldMinor))
  }

  private func thousandths(of minor: Int64) -> Int {
    guard goal.targetMinor > 0 else { return 1000 }
    return Int(min(1000, Exact.floorDivide(Int128(max(0, minor)) * 1000, Int128(goal.targetMinor))))
  }
}

/// How savings divide among the goals. Nothing fills while savings are below zero: deposits repay that first. Then the active goals fill one after another
/// by rank (`SavingsGoalRecord.precedes`), each up to its target, and what is left is unallocated.
///
/// A purchase (an expense naming an active goal) draws its savings part from that goal's share first: the goals fill as though the goal's own draws were
/// still in savings, and the goal keeps its fill less its draws. What a purchase draws beyond the goal's fill comes out of what would be left after every
/// goal, then out of the goals after it, the last first. Once bought, the goal leaves the fill: its draws stay out of the balance and whatever its fill held
/// beyond them returns to the pool, as an abandoned goal's whole share does. Draws naming a goal that is bought, abandoned or deleted count as any other
/// withdrawal. A goal in a currency other than home (made while two devices disagreed on it) takes no share.
public struct SavingsAllocation: Sendable, Hashable {
  /// The active goals in fill order.
  public let active: [GoalShare]
  /// Bought and abandoned goals, by rank, holding nothing.
  public let settled: [GoalShare]
  public let otherCurrency: [SavingsGoalRecord]
  public let unallocatedMinor: Int64
  /// What deposits repay before any goal fills.
  public let owedMinor: Int64

  public func share(of goal: UUID) -> GoalShare? {
    active.first { $0.id == goal } ?? settled.first { $0.id == goal }
  }

  static func make(balanceMinor: Int64, goals: [SavingsGoalRecord], home: CurrencyCode, withdrawals: [SavingsWithdrawal]) -> SavingsAllocation {
    var drawn = [UUID: Int128]()
    for withdrawal in withdrawals {
      guard let goal = withdrawal.goal, let minor = withdrawal.amount.minor else { continue }
      drawn[goal, default: 0] += Int128(minor)
    }
    let ordered = goals.sorted(by: SavingsGoalRecord.precedes)
    let active = ordered.filter { $0.state == .known(.active) && $0.currency == home }
    let settled = ordered.filter { $0.state != .known(.active) && $0.currency == home }
    let balance = Int128(balanceMinor)
    var remaining = balance + active.reduce(Int128(0)) { $0 + (drawn[$1.id] ?? 0) }
    var nets = [Int128]()
    var fills = [Int128]()
    for goal in active {
      let own = drawn[goal.id] ?? 0
      let fill = min(Int128(max(0, goal.targetMinor)), max(0, remaining))
      remaining -= max(fill, own)
      nets.append(max(0, fill - own))
      fills.append(fill)
    }
    if balance <= 0 {
      nets = nets.map { _ in 0 }
      remaining = 0
    } else if remaining < 0 {
      var deficit = -remaining
      for index in nets.indices.reversed() where deficit > 0 {
        let taken = min(nets[index], deficit)
        nets[index] -= taken
        deficit -= taken
      }
      remaining = 0
    }
    return SavingsAllocation(
      active: active.indices.map { index in
        GoalShare(
          goal: active[index], shareMinor: Int64(clamping: nets[index]), drawnMinor: Int64(clamping: drawn[active[index].id] ?? 0),
          heldMinor: Int64(clamping: fills[index]))
      },
      settled: settled.map { GoalShare(goal: $0, shareMinor: 0, drawnMinor: Int64(clamping: drawn[$0.id] ?? 0), heldMinor: 0) },
      otherCurrency: ordered.filter { $0.currency != home }, unallocatedMinor: Int64(clamping: remaining), owedMinor: Int64(clamping: max(0, -balance)))
  }
}
