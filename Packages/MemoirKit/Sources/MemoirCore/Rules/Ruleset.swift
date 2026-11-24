public struct Ruleset: Sendable, Hashable, Encodable {
  public let version: Int
  public let strictness: RuleTable<Strictness, StrictnessRules>
  public let reward: RewardRules
  public let level: LevelCurve
  public let streaks: StreakRules
  public let shields: ShieldRules
  public let intensityModes: RuleTable<IntensityMode, IntensityModeRules>
  public let crown: CrownRules
  public let recovery: RecoveryRules
  public let comeback: ComebackRules
  public let returner: ReturnerRules
  public let momentum: MomentumRules
  public let capacity: CapacityRules
  public let reasonTags: [ReasonTag]
  public let quickLogs: RuleTable<QuickLogSource, QuickLogReward>
  public let subscriptionConfirmationCoins: Int
  /// Nil before v2, and then left out of the encoding, so v1's canonical bytes stay as published.
  public private(set) var money: MoneyRules?

  public static let current = v2

  public static func version(_ version: Int) -> Ruleset? {
    switch version {
    case v1.version: v1
    case v2.version: v2
    default: nil
    }
  }
}

public struct StrictnessRules: Sendable, Hashable, Encodable {
  public let schedulingModel: SchedulingModel
  public let crownWeight: Halves
  public let incursHPCost: Bool
  public let triggersRecovery: Bool
  public let streakEligibility: StreakEligibility
  public let allowsPostpone: Bool
  public let consumesOneShot: Bool
}

public struct TimingRules: Sendable, Hashable, Encodable {
  public let anchorGraceMinutes: Int
  public let lateStepMinutes: Int
}

public struct OneShotXPModifiers: Sendable, Hashable, Encodable {
  public let returner: Thousandths
  public let comeback: Thousandths
}

public struct RewardRules: Sendable, Hashable, Encodable {
  public let baseXP: RuleTable<Strictness, RuleTable<TimingBand, Int>>
  public let baseCoins: RuleTable<Strictness, Int>
  public let partialXPFactor: Thousandths
  public let lockXPModifier: Thousandths
  public let oneShotXPModifiers: OneShotXPModifiers
  public let comebackCoinBonus: Int
  public let xpCeiling: Int
  public let statTick: Int
  public let timing: TimingRules
}

public struct StreakTier: Sendable, Hashable, Encodable {
  public let id: StreakTierID
  public let minDays: Int
  public let xpModifier: Thousandths
}

public struct StreakRules: Sendable, Hashable, Encodable {
  public let floorTier: StreakTier
  public let higherTiers: [StreakTier]
  public let breakAnnounceMinDays: Int

  public var tiers: [StreakTier] { [floorTier] + higherTiers }

  private enum CodingKeys: String, CodingKey {
    case tiers
    case breakAnnounceMinDays
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(tiers, forKey: .tiers)
    try container.encode(breakAnnounceMinDays, forKey: .breakAnnounceMinDays)
  }
}

public struct ShieldRules: Sendable, Hashable, Encodable {
  public let capPerQuest: Int
  public let expires: Bool
  public let returnerGrant: Int
}

public struct HPCostRules: Sendable, Hashable, Encodable {
  public let perBreak: Int
  public let perBreakEndingHighStreak: Int
}

public enum ComebackTrigger: Sendable, Hashable, Encodable {
  case anchorMissYesterday
  case missWithinDays(days: Int, strictness: [Strictness], requiresColdMomentum: Bool)

  private enum CodingKeys: String, CodingKey {
    case kind
    case days
    case strictness
    case requiresColdMomentum
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .anchorMissYesterday:
      try container.encode("anchor_miss_yesterday", forKey: .kind)
    case .missWithinDays(let days, let strictness, let requiresColdMomentum):
      try container.encode("miss_within_days", forKey: .kind)
      try container.encode(days, forKey: .days)
      try container.encode(strictness, forKey: .strictness)
      try container.encode(requiresColdMomentum, forKey: .requiresColdMomentum)
    }
  }
}

public struct IntensityModeRules: Sendable, Hashable, Encodable {
  public let hpMax: Int
  public let overnightHPRegen: Int
  public let crownCadence: CrownCadence
  public let shieldEarnCadence: Int
  public let hpCost: HPCostRules
  public let comebackTriggers: [ComebackTrigger]
}

public struct CrownRules: Sendable, Hashable, Encodable {
  public let xpPerWeight: Int
  public let coinsWeightDivisor: Int
  public let maxCoins: Int
  public let weeklyAnchorWeekday: LocalDate.Weekday

  private enum CodingKeys: String, CodingKey {
    case xpPerWeight
    case coinsWeightDivisor
    case maxCoins
    case weeklyAnchorWeekday
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(xpPerWeight, forKey: .xpPerWeight)
    try container.encode(coinsWeightDivisor, forKey: .coinsWeightDivisor)
    try container.encode(maxCoins, forKey: .maxCoins)
    try container.encode(weeklyAnchorWeekday.rawValue, forKey: .weeklyAnchorWeekday)
  }
}

public struct RecoveryRules: Sendable, Hashable, Encodable {
  public let maxPerDay: Int
  public let triggeredByStrictness: [Strictness]
}

public struct ComebackRules: Sendable, Hashable, Encodable {
  public let maxFiresPerDay: Int
  public let maxFiresPerDayViaRecovery: Int
}

public struct ReturnerRules: Sendable, Hashable, Encodable {
  public let defaultThresholdDays: Int
  public let shieldGrant: Int
  public let suppressesComeback: Bool
}

public struct MomentumRules: Sendable, Hashable, Encodable {
  public let recentDayWeights: [Tenths]
  public let medianWindowDays: Int
  public let coldBelowRatio: Thousandths
  public let warmAboveRatio: Thousandths
}

public struct CapacityRules: Sendable, Hashable, Encodable {
  public let newUserBaselineCap: Int
  public let ratchetFactor: Thousandths
  public let medianWindowDays: Int
  public let coldMomentumFactor: Thousandths
  public let heavyMissDayFactor: Thousandths
  public let softWarningRatio: Thousandths
  public let modalWarningRatio: Thousandths
  public let softWarningThrottleDays: Int
  public let anchorWarnAboveCount: Int
}

public struct QuickLogReward: Sendable, Hashable, Encodable {
  public let xp: Int
  public let coins: Int
  public let statTick: Int
  public let maxRewardedPerDay: Int
}
