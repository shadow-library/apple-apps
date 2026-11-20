/// Every input the achievement and title catalogues read. All but `reschedulesWithReasonIn90Days` are lifetime counters that only grow.
public struct ProgressCounters: Sendable, Hashable {
  public static let empty = ProgressCounters()

  public var totalXP = 0
  public var level = 1
  public var stats = RuleTable<StatAffinity, Int> { _ in 0 }
  public var questsCompleted = 0
  public var completionsByStrictness = RuleTable<Strictness, Int> { _ in 0 }
  public var longestStreakDays = 0
  public var longestAnchorStreakDays = 0
  public var questsReachingSilverStreak = 0
  public var subscriptionsConfirmed = 0
  public var receiptsScanned = 0
  public var fullHPDays = 0
  public var crownsBanked = 0
  public var lockedDaysCleared = 0
  public var comebackBonusesClaimed = 0
  public var returnerRitualsCompleted = 0
  public var completionsAfterReturner = 0
  public var reschedulesWithReasonIn90Days = 0
  public var reasonTaggedEvents = 0
  public var activeDays = 0

  public init() {}
}

public enum AchievementID: String, RuleKey {
  case firstQuestCompleted = "first_quest_completed"
  case firstLevelUp = "first_level_up"
  case firstBronzeStreak = "first_bronze_streak"
  case firstSilverStreak = "first_silver_streak"
  case firstGoldStreak = "first_gold_streak"
  case firstPlatinumStreak = "first_platinum_streak"
  case xp100 = "xp_100"
  case xp500 = "xp_500"
  case firstSubscriptionConfirmed = "first_subscription_confirmed"
  case firstReceiptScanned = "first_receipt_scanned"
  case allStatsTouched = "all_stats_touched"
  case firstFullHPDay = "first_full_hp_day"
  case firstCrownBanked = "first_crown_banked"
  case firstRecoveryCompleted = "first_recovery_completed"
  case firstLockedDayCleared = "first_locked_day_cleared"
  case firstComebackClaimed = "first_comeback_claimed"
  case firstReturnerRitual = "first_returner_ritual"
}

public enum TitleID: String, RuleKey {
  case steadyBuilder = "steady_builder"
  case bodyTempered = "body_tempered"
  case wealthDisciplined = "wealth_disciplined"
  case mindCultivated = "mind_cultivated"
  case anchorHolder = "anchor_holder"
  case goalKeeper = "goal_keeper"
  case routineForged = "routine_forged"
  case quietClimber = "quiet_climber"
  case architect
  case honestPlanner = "honest_planner"
  case reflectivePractitioner = "reflective_practitioner"
  case restorer
  case returner
  case comebackSteady = "comeback_steady"
  case optionalSurplus = "optional_surplus"
  case crossStatClimber = "cross_stat_climber"
  case quietYear = "quiet_year"
}

extension Ruleset {
  public func isSatisfied(_ achievement: AchievementID, by counters: ProgressCounters) -> Bool {
    switch achievement {
    case .firstQuestCompleted: counters.questsCompleted >= 1
    case .firstLevelUp: counters.level >= 2
    case .firstBronzeStreak: reaches(counters.longestStreakDays, .bronze)
    case .firstSilverStreak: reaches(counters.longestStreakDays, .silver)
    case .firstGoldStreak: reaches(counters.longestStreakDays, .gold)
    case .firstPlatinumStreak: reaches(counters.longestStreakDays, .platinum)
    case .xp100: counters.totalXP >= 100
    case .xp500: counters.totalXP >= 500
    case .firstSubscriptionConfirmed: counters.subscriptionsConfirmed >= 1
    case .firstReceiptScanned: counters.receiptsScanned >= 1
    case .allStatsTouched: counters.stats.entries.allSatisfy { $0.value >= 1 }
    case .firstFullHPDay: counters.fullHPDays >= 1
    case .firstCrownBanked: counters.crownsBanked >= 1
    case .firstRecoveryCompleted: counters.completionsByStrictness[.recovery] >= 1
    case .firstLockedDayCleared: counters.lockedDaysCleared >= 1
    case .firstComebackClaimed: counters.comebackBonusesClaimed >= 1
    case .firstReturnerRitual: counters.returnerRitualsCompleted >= 1
    }
  }

  public func isSatisfied(_ title: TitleID, by counters: ProgressCounters) -> Bool {
    switch title {
    case .steadyBuilder: counters.stats[.discipline] >= Self.statTitleThreshold
    case .bodyTempered: counters.stats[.body] >= Self.statTitleThreshold
    case .wealthDisciplined: counters.stats[.wealth] >= Self.statTitleThreshold
    case .mindCultivated: counters.stats[.mind] >= Self.statTitleThreshold
    case .anchorHolder: reaches(counters.longestAnchorStreakDays, .gold)
    case .goalKeeper: counters.completionsByStrictness[.goal] >= 30
    case .routineForged: counters.completionsByStrictness[.routine] >= 100
    case .quietClimber: counters.questsReachingSilverStreak >= 3
    case .architect: counters.lockedDaysCleared >= 10
    case .honestPlanner: counters.reschedulesWithReasonIn90Days >= 10
    case .reflectivePractitioner: counters.reasonTaggedEvents >= 20
    case .restorer: counters.completionsByStrictness[.recovery] >= 5
    case .returner: counters.completionsAfterReturner >= 1
    case .comebackSteady: counters.comebackBonusesClaimed >= 10
    case .optionalSurplus: counters.completionsByStrictness[.optional] >= 30
    case .crossStatClimber: counters.stats.entries.allSatisfy { $0.value >= Self.crossStatThreshold }
    case .quietYear: counters.activeDays >= 365
    }
  }

  public func satisfiedAchievements(_ counters: ProgressCounters) -> [AchievementID] {
    AchievementID.allCases.filter { isSatisfied($0, by: counters) }
  }

  public func unlockedAchievements(_ counters: ProgressCounters, earned: [AchievementID]) -> [AchievementID] {
    satisfiedAchievements(counters).filter { !earned.contains($0) }
  }

  /// A grant is kept forever once its predicate held on any one snapshot.
  public func recomputeAchievements(_ snapshots: [ProgressCounters]) -> [AchievementID] {
    let earned = Set(snapshots.flatMap(satisfiedAchievements))
    return AchievementID.allCases.filter(earned.contains)
  }

  public func satisfiedTitles(_ counters: ProgressCounters) -> [TitleID] {
    TitleID.allCases.filter { isSatisfied($0, by: counters) }
  }

  public func unlockedTitles(_ counters: ProgressCounters, earned: [TitleID]) -> [TitleID] {
    satisfiedTitles(counters).filter { !earned.contains($0) }
  }

  /// Titles are kept forever, so the rolling-window predicates are replayed over every snapshot rather than tested against today.
  public func recomputeTitles(_ snapshots: [ProgressCounters]) -> [TitleID] {
    let earned = Set(snapshots.flatMap(satisfiedTitles))
    return TitleID.allCases.filter(earned.contains)
  }

  private static let statTitleThreshold = 60
  private static let crossStatThreshold = 30

  private func reaches(_ days: Int, _ tier: StreakTierID) -> Bool {
    streakTierMinDays(tier).map { days >= $0 } ?? false
  }
}
