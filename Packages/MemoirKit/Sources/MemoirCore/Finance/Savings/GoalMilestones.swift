import Foundation
import ShadowCore
import ShadowStore

/// A milestone a goal has reached and replay has not rewarded yet.
public struct GoalMilestoneCrossing: Sendable, Hashable {
  public let goal: UUID
  public let milestone: GoalMilestone

  public init(goal: UUID, milestone: GoalMilestone) {
    self.goal = goal
    self.milestone = milestone
  }
}

/// The milestones goals have reached, and the only writer of `goal.milestone`. A milestone is due for an active goal that earns rewards
/// (`GoalRewardEligibility`) once what savings gathered for it (`GoalShare.savedThousandths`: its draws count, but never beyond what the pool held, so
/// borrowing earns nothing) reaches it, until replay records it (`MemoirDerived.goalRewards`); every milestone the goal has passed is due at once. Nothing
/// is due while replay is halted. Two devices issuing the same one leave one reward: replay supersedes the later. `GoalEdits.markBought` issues the
/// goal's own before it leaves the active goals.
public enum GoalMilestones {
  public static func due(in stores: MemoirStores, today: LocalDate) async throws(MemoirReadError) -> [GoalMilestoneCrossing] {
    try await readCall { () async throws(StoreError) in
      try await stores.main.read { transaction in try due(in: transaction, today: today) }
    }
  }

  public static func due(in transaction: ReadTransaction, today: LocalDate) throws(MemoirReadError) -> [GoalMilestoneCrossing] {
    let book = try SavingsBook.load(from: transaction)
    var rewarded = Set<GoalMilestoneCrossing>()
    do throws(StoreError) {
      for goal in book.goals where goal.state == .known(.active) {
        for row in try MemoirDerived.goalRewards(of: goal.id, in: transaction) {
          if case .milestone(let milestone) = row.reward { rewarded.insert(GoalMilestoneCrossing(goal: goal.id, milestone: milestone)) }
        }
      }
    } catch {
      throw MemoirReadError(error)
    }
    return due(book, rewarded: rewarded, today: today)
  }

  /// In fill order, each goal's milestones in order.
  static func due(_ book: SavingsBook, rewarded: Set<GoalMilestoneCrossing>, today: LocalDate) -> [GoalMilestoneCrossing] {
    guard book.budgets.replayHalt == nil, let converter = book.converter else { return [] }
    let balance = SavingsBalance.make(book, converter: converter, today: today)
    let allocation = SavingsAllocation.make(
      balanceMinor: balance.balanceMinor, goals: book.goals, home: converter.home, withdrawals: book.withdrawals(converter: converter))
    let home = book.budgets.liveBudgets(today: today).first(where: \.isHome)
    return allocation.active.flatMap { share -> [GoalMilestoneCrossing] in
      guard GoalRewardEligibility.of(share.goal, home: home, converter: converter).isEligible else { return [] }
      return GoalMilestone.allCases.filter { share.savedThousandths >= $0.thousandths }.map { GoalMilestoneCrossing(goal: share.id, milestone: $0) }
        .filter { !rewarded.contains($0) }
    }
  }

  /// Issues every milestone due on the account's day, as the write reads the vault, in the caller's main-store write; none when nothing is due.
  @discardableResult
  public static func issue(issuer: CommandIssuer, in transaction: inout WriteTransaction) throws(CommandIssueError) -> [MemoirCommand] {
    try issue(of: nil, issuer: issuer, in: &transaction)
  }

  /// Only `goal`'s milestones when it is given.
  static func issue(of goal: UUID?, issuer: CommandIssuer, in transaction: inout WriteTransaction) throws(CommandIssueError) -> [MemoirCommand] {
    let source = ReadTransaction(database: transaction.database, registry: MemoirSchema.mainRegistry)
    let zone: AccountZone
    do throws(StoreError) {
      zone = try AccountZone.load(in: source)
    } catch {
      throw .record(.store(error))
    }
    let today = try issuer.accountToday(openDay: zone.openDay)
    let crossings: [GoalMilestoneCrossing]
    do throws(MemoirReadError) {
      crossings = try due(in: source, today: today).filter { crossing in goal.map { $0 == crossing.goal } ?? true }
    } catch {
      throw CommandIssueError(reading: error)
    }
    var commands = [MemoirCommand]()
    for crossing in crossings {
      commands.append(try issuer.issue(.goalMilestone(GoalMilestoneReached(goalId: crossing.goal, milestone: crossing.milestone)), in: &transaction))
    }
    return commands
  }
}

extension GoalMilestone {
  /// The progress a goal reaches the milestone at, in thousandths of its target.
  var thousandths: Int {
    switch self {
    case .p25: 250
    case .p50: 500
    case .p75: 750
    case .p100: 1000
    }
  }
}
