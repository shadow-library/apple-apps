import Foundation

/// What covered a day's money logging: an expense dated that day, or the owner saying nothing was spent.
public enum MoneyLogSource: String, RuleKey, Codable {
  case expense
  case noSpend = "no_spend"
}

/// The first command that covered a day, in replay order.
public struct MoneyCoverage: Sendable, Hashable, Codable {
  public let source: MoneyLogSource
  public let command: UUID
}

/// A budget's period, as `budget.closePeriod` names it.
public struct MoneyCloseKey: Sendable, Hashable, Codable {
  public let budget: UUID
  public let periodStart: LocalDate

  public init(budget: UUID, periodStart: LocalDate) {
    self.budget = budget
    self.periodStart = periodStart
  }
}

/// An XP multiplier a penalty close put on the days from `from` through `through`.
public struct MoneyDebuffSpan: Sendable, Hashable, Codable {
  public let from: LocalDate
  public let through: LocalDate
  public let multiplier: Thousandths
  public let command: UUID

  public func covers(_ date: LocalDate) -> Bool {
    from <= date && date <= through
  }
}

/// What a close did to the hero: a reward credited, or a fine (the intended one, and what the balance allowed) with its debuff.
public enum MoneyCloseResult: Sendable, Hashable {
  case rewarded(RewardAmount)
  case fined(intended: Int, applied: Int, debuff: MoneyDebuffSpan)
}

/// The close replay kept for a period: the earliest `budget.closePeriod` for it in replay order.
public struct MoneyClose: Sendable, Hashable {
  public let command: UUID
  public let outcome: BudgetCloseOutcome
  public let deposited: Bool
  /// The account's day when the close was issued, the first day of its debuff.
  public let closedOn: LocalDate
  public let result: MoneyCloseResult
}

public struct GoalMilestoneKey: Sendable, Hashable, Codable {
  public let goal: UUID
  public let milestone: GoalMilestone
}

/// Money in the game (ruleset v2): which days the owner's logging covered, the weekly money streak, the saving streak, every period close, the goal
/// rewards already given, and the debuffs still able to reach a grant.
public struct MoneyState: Sendable, Hashable {
  public static let empty = MoneyState()

  public internal(set) var coveredDays: [LocalDate: MoneyCoverage] = [:]
  /// The latest account day a money command was taken in under money rules, which the Returner reads as activity beside the quests'.
  public internal(set) var lastActivityDay: LocalDate?
  /// Consecutive settled weeks with enough covered days.
  public internal(set) var weekStreak = 0
  public internal(set) var lastSettledWeekStart: LocalDate?
  /// Closes that deposited into savings since the last close over its limit or unscored; a close within the limit without a deposit does not break it.
  public internal(set) var savingStreak = 0
  public internal(set) var closes: [MoneyCloseKey: MoneyClose] = [:]
  public internal(set) var milestones: Set<GoalMilestoneKey> = []
  public internal(set) var goalsBought: Set<UUID> = []
  /// Debuffs in the order their closes were taken in; one that ended more than the late window before a closed day is dropped.
  public internal(set) var debuffs: [MoneyDebuffSpan] = []

  /// The strongest debuff covering `date`, so debuffs never stack and the later end still holds once a stronger one has ended; nil when none does.
  public func debuffMultiplier(on date: LocalDate) -> Thousandths? {
    debuffs.filter { $0.covers(date) }.map(\.multiplier).min()
  }

  /// The latest last day among the debuffs covering `date`; nil when none does.
  public func debuffEnd(on date: LocalDate) -> LocalDate? {
    debuffs.filter { $0.covers(date) }.map(\.through).max()
  }
}
