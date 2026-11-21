public enum Strictness: String, RuleKey, Codable {
  case anchor
  case routine
  case goal
  case recovery
  case optional
}

public enum StatAffinity: String, RuleKey, Codable {
  case discipline
  case body
  case wealth
  case mind
}

public enum IntensityMode: String, RuleKey, Codable {
  case standard
  case lowIntensity = "low_intensity"
  case highIntensity = "high_intensity"
}

public enum SchedulingModel: String, RuleKey, Codable {
  case strictTime = "strict_time"
  case timeWindow = "time_window"
  case dayLevel = "day_level"
}

public enum StreakEligibility: String, RuleKey, Codable {
  case always
  case optIn = "opt_in"
  case never
}

public enum TimingBand: String, RuleKey, Codable {
  case onTime = "on_time"
  case late0To2h = "late_0_2h"
  case late2hPlus = "late_2h_plus"
  case day1 = "day_1"
  case day2 = "day_2"
  case day3 = "day_3"
  case day4 = "day_4"
}

public enum CompletionKind: String, RuleKey, Codable {
  case full
  case partial
}

public enum QuestLogState: String, RuleKey, Codable {
  case completed
  case partial
  case late
  case skipped
  case missed
  case postponed
  case rescheduled
  case recovery
}

public enum OneShotModifier: String, RuleKey, Codable {
  case none
  case returner
  case comeback
}

public enum StreakTierID: String, RuleKey, Codable {
  case none
  case bronze
  case silver
  case gold
  case platinum
}

public enum CrownCadence: String, RuleKey, Codable {
  case daily
  case weekly
}

public enum MomentumBucket: String, RuleKey, Codable {
  case cold
  case steady
  case warm
}

public enum QuickLogSource: String, RuleKey, Codable {
  case journal
  case meal
  case weight
  case sideQuest = "side_quest"
}

public enum ReasonTag: String, RuleKey, Codable {
  case forgot
  case tooTired = "too_tired"
  case taskTooBig = "task_too_big"
  case scheduleConflict = "schedule_conflict"
  case avoidedIt = "avoided_it"
  case emotionalResistance = "emotional_resistance"
  case health
  case travel
  case familySocial = "family_social"
  case workEmergency = "work_emergency"
  case notImportantAnymore = "not_important_anymore"
  case poorlyPlanned = "poorly_planned"
  case other
}

public struct RewardAmount: Sendable, Hashable {
  public static let zero = RewardAmount(xp: 0, coins: 0)

  public let xp: Int
  public let coins: Int

  public init(xp: Int, coins: Int) {
    self.xp = xp
    self.coins = coins
  }
}
