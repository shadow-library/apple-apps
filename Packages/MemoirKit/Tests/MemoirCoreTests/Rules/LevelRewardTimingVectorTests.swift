import MemoirCore
import Testing

@Suite("Level, reward and timing vectors", TestTimeLimit.standard)
struct LevelRewardTimingVectorTests {
  private let ruleset = Ruleset.v1

  @Test("should cost each level what the reference curve costs")
  func xpToAdvance() throws {
    try RuleVectors.check("level.json", "xpToAdvance") { .int(ruleset.level.xpToAdvance(fromLevel: try $0.int)) }
  }

  @Test("should place every level at the reference's lifetime XP threshold")
  func thresholds() throws {
    try RuleVectors.check("level.json", "xpThresholdForLevel") { .int(ruleset.level.xpThreshold(forLevel: try $0.int)) }
  }

  @Test("should resolve the level on, below and above every threshold")
  func levelFor() throws {
    try RuleVectors.check("level.json", "levelFor") { .int(ruleset.level.level(forTotalXP: try $0.int)) }
  }

  @Test("should resolve the streak tier and its modifier for every streak length")
  func streakTier() throws {
    try RuleVectors.check("reward.json", "streakTierFor") { input in
      let tier = ruleset.streakTier(forStreakDays: try input.int)
      return .object(["id": .string(tier.id.rawValue), "minDays": .int(tier.minDays), "xpModifier": .fraction(tier.xpModifier.fraction)])
    }
    try RuleVectors.check("reward.json", "streakTierMinDays") { .int(ruleset.streakTierMinDays(try $0.key()) ?? .max) }
  }

  @Test("should reward the spec cases and the whole strictness, band, completion, tier, lock and one-shot domain")
  func reward() throws {
    try RuleVectors.check("reward.json", "computeReward") { FixtureValue(ruleset.reward(for: try $0.rewardInput)) }
  }

  @Test("should resolve the timing band of the spec cases")
  func timingSpec() throws {
    try RuleVectors.check("timing.json", "resolveTimingBand") { input in
      .string(ruleset.timingBand(for: try Self.timingInput(input, minuteOfDay: try input["minuteOfDay"].int)).rawValue)
    }
  }

  @Test("should resolve the timing band of every minute of the day for each strictness, start, duration and elapsed-day offset")
  func timingEveryMinute() throws {
    try RuleVectors.check("timing.json", "everyMinute") { input in
      var runs: [(band: TimingBand, count: Int)] = []
      for minute in 0..<1440 {
        let band = ruleset.timingBand(for: try Self.timingInput(input, minuteOfDay: minute))
        if let last = runs.last, last.band == band {
          runs[runs.count - 1].count += 1
        } else {
          runs.append((band, 1))
        }
      }
      return .array(runs.map { .array([.string($0.band.rawValue), .int($0.count)]) })
    }
  }

  @Test("should keep XP within the ceiling and never consume a one-shot on a strictness that cannot be punished")
  func rewardBounds() {
    for input in Self.domain {
      let outcome = ruleset.reward(for: input)
      #expect((0...ruleset.reward.xpCeiling).contains(outcome.xp))
      #expect(outcome.coins >= 0)
      if !ruleset.strictness[input.strictness].consumesOneShot { #expect(outcome.oneShotConsumed == .none) }
    }
  }

  private static var domain: [RewardInput] {
    Strictness.allCases.flatMap { strictness in
      TimingBand.allCases.flatMap { band in
        [-100, 0, 3, 7, 30, 100, 1_099, .max].flatMap { streakDays in
          OneShotModifier.allCases.flatMap { oneShot in
            [true, false].flatMap { lockActive in
              CompletionKind.allCases.map {
                RewardInput(strictness: strictness, band: band, completion: $0, streakDays: streakDays, lockActive: lockActive, oneShot: oneShot)
              }
            }
          }
        }
      }
    }
  }

  private static func timingInput(_ input: FixtureValue, minuteOfDay: Int) throws -> TimingBandInput {
    TimingBandInput(
      strictness: try input["strictness"].key(),
      startMinute: try input["startMinute"].optionalInt,
      durationMinutes: try input["durationMinutes"].int,
      daysElapsed: try input["daysElapsed"].int,
      minuteOfDay: minuteOfDay
    )
  }
}
