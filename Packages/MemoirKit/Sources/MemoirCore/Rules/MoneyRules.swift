/// How a budget period closed, as `budget.closePeriod` names it: within the limit and at or under the typical month, within the limit, over it by at most
/// 10% or 25%, over by more, or unscored because too few of its days were logged.
public enum BudgetCloseOutcome: String, RuleKey, Codable {
  case withinTypical = "within_typical"
  case within
  case over10 = "over_10"
  case over25 = "over_25"
  case overMore = "over_more"
  case unscored
}

public enum GoalMilestone: String, RuleKey, Codable {
  case p25
  case p50
  case p75
  case p100
}

public enum GoalPurchaseOutcome: String, RuleKey, Codable {
  case within
  case over
}

/// An XP multiplier over a run of days, counted from the day the period closed.
public struct MoneyDebuff: Sendable, Hashable, Encodable {
  public let multiplier: Thousandths
  public let days: Int

  public init(multiplier: Thousandths, days: Int) {
    self.multiplier = multiplier
    self.days = days
  }
}

/// What closing a period does to the hero: a reward, or a coin fine with a debuff, which also resets the money streak.
public enum MoneyCloseEffect: Sendable, Hashable, Encodable {
  case reward(RewardAmount)
  case penalty(fine: Int, debuff: MoneyDebuff)

  private enum CodingKeys: String, CodingKey {
    case kind
    case xp
    case coins
    case fine
    case debuff
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .reward(let amount):
      try container.encode("reward", forKey: .kind)
      try container.encode(amount.xp, forKey: .xp)
      try container.encode(amount.coins, forKey: .coins)
    case .penalty(let fine, let debuff):
      try container.encode("penalty", forKey: .kind)
      try container.encode(fine, forKey: .fine)
      try container.encode(debuff, forKey: .debuff)
    }
  }

  func scaled(by factor: Thousandths) -> MoneyCloseEffect {
    switch self {
    case .reward(let amount): .reward(amount.scaled(by: factor))
    case .penalty(let fine, let debuff):
      .penalty(fine: MoneyScale.apply(fine, factor), debuff: MoneyDebuff(multiplier: debuff.multiplier, days: MoneyScale.apply(debuff.days, factor)))
    }
  }
}

/// An intensity's share of the standard money table; the exact product rounds half up.
enum MoneyScale {
  static func factor(of mode: IntensityMode) -> Thousandths {
    switch mode {
    case .standard: Thousandths(1000)
    case .lowIntensity: Thousandths(500)
    case .highIntensity: Thousandths(1500)
    }
  }

  static func apply(_ value: Int, _ factor: Thousandths) -> Int {
    Int(clamping: Exact.roundHalfUp(Int128(value) * Int128(factor.thousandths), 1000))
  }
}

extension RewardAmount {
  fileprivate func scaled(by factor: Thousandths) -> RewardAmount {
    RewardAmount(xp: MoneyScale.apply(xp, factor), coins: MoneyScale.apply(coins, factor))
  }
}

/// Money in the game, from ruleset v2: which logging covers a day, the weekly money streak, when a period closes, and what a close, a goal milestone and a
/// goal bought within its target are worth.
public struct MoneyRules: Sendable, Hashable, Encodable {
  /// A day is covered only by logging done on it or at most this many days later.
  public let lateDays: Int
  public let dailyLog: RuleTable<IntensityMode, RewardAmount>
  public let weekAnchorWeekday: LocalDate.Weekday
  /// Covered days a week needs to extend the money streak.
  public let weekMinCovered: Int
  /// The share of a period's days that must be covered for its close to be scored.
  public let coverageThreshold: Thousandths
  /// Days after a period ends before it closes.
  public let closeGraceDays: Int
  /// Days a close may wait beyond the grace for pending conversions.
  public let pendingHoldDays: Int
  public let close: RuleTable<IntensityMode, RuleTable<BudgetCloseOutcome, MoneyCloseEffect>>
  public let milestones: RuleTable<IntensityMode, RuleTable<GoalMilestone, RewardAmount>>
  public let goalPurchase: RuleTable<IntensityMode, RuleTable<GoalPurchaseOutcome, RewardAmount>>

  private enum CodingKeys: String, CodingKey {
    case lateDays
    case dailyLog
    case weekAnchorWeekday
    case weekMinCovered
    case coverageThreshold
    case closeGraceDays
    case pendingHoldDays
    case close
    case milestones
    case goalPurchase
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(lateDays, forKey: .lateDays)
    try container.encode(dailyLog, forKey: .dailyLog)
    try container.encode(weekAnchorWeekday.rawValue, forKey: .weekAnchorWeekday)
    try container.encode(weekMinCovered, forKey: .weekMinCovered)
    try container.encode(coverageThreshold, forKey: .coverageThreshold)
    try container.encode(closeGraceDays, forKey: .closeGraceDays)
    try container.encode(pendingHoldDays, forKey: .pendingHoldDays)
    try container.encode(close, forKey: .close)
    try container.encode(milestones, forKey: .milestones)
    try container.encode(goalPurchase, forKey: .goalPurchase)
  }
}

extension MoneyRules {
  /// Published with ruleset v2 and frozen like it. Low intensity halves and high intensity multiplies by 1.5 the standard table's XP, coins, fines and
  /// debuff days; debuff multipliers do not scale.
  public static let v2 = MoneyRules(
    lateDays: 2,
    dailyLog: RuleTable { mode in RewardAmount(xp: 3, coins: 0).scaled(by: MoneyScale.factor(of: mode)) },
    weekAnchorWeekday: .monday,
    weekMinCovered: 5,
    coverageThreshold: Thousandths(600),
    closeGraceDays: 3,
    pendingHoldDays: 7,
    close: RuleTable { mode in RuleTable { outcome in standardClose(outcome).scaled(by: MoneyScale.factor(of: mode)) } },
    milestones: RuleTable { mode in RuleTable { milestone in standardMilestone(milestone).scaled(by: MoneyScale.factor(of: mode)) } },
    goalPurchase: RuleTable { mode in RuleTable { outcome in standardGoalPurchase(outcome).scaled(by: MoneyScale.factor(of: mode)) } }
  )

  private static func standardClose(_ outcome: BudgetCloseOutcome) -> MoneyCloseEffect {
    switch outcome {
    case .withinTypical: .reward(RewardAmount(xp: 40, coins: 8))
    case .within: .reward(RewardAmount(xp: 20, coins: 3))
    case .over10: .penalty(fine: 15, debuff: MoneyDebuff(multiplier: Thousandths(850), days: 7))
    case .over25: .penalty(fine: 30, debuff: MoneyDebuff(multiplier: Thousandths(750), days: 14))
    case .overMore, .unscored: .penalty(fine: 60, debuff: MoneyDebuff(multiplier: Thousandths(600), days: 30))
    }
  }

  private static func standardMilestone(_ milestone: GoalMilestone) -> RewardAmount {
    switch milestone {
    case .p25, .p50: RewardAmount(xp: 10, coins: 0)
    case .p75: RewardAmount(xp: 15, coins: 0)
    case .p100: RewardAmount(xp: 30, coins: 5)
    }
  }

  private static func standardGoalPurchase(_ outcome: GoalPurchaseOutcome) -> RewardAmount {
    switch outcome {
    case .within: RewardAmount(xp: 30, coins: 5)
    case .over: .zero
    }
  }
}

extension Ruleset {
  public static func debuffed(xp: Int, multiplier: Thousandths) -> Int {
    Int(clamping: Exact.floorDivide(Int128(xp) * Int128(multiplier.thousandths), 1000))
  }
}
