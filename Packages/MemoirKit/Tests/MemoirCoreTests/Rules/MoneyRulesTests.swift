import MemoirCore
import Testing

@Suite("Money rules", TestTimeLimit.quick)
struct MoneyRulesTests {
  private static let money = Ruleset.v2.money

  private static func reward(_ xp: Int, _ coins: Int) -> MoneyCloseEffect { .reward(RewardAmount(xp: xp, coins: coins)) }

  private static func penalty(_ fine: Int, _ multiplier: Int, _ days: Int) -> MoneyCloseEffect {
    .penalty(fine: fine, debuff: MoneyDebuff(multiplier: Thousandths(multiplier), days: days))
  }

  @Test func shouldHoldTheLoggingAndClosingRulesOfVersionTwo() throws {
    let money = try #require(Self.money)
    #expect(money.lateDays == 2)
    #expect(money.dailyLog[.standard] == RewardAmount(xp: 3, coins: 0))
    #expect(money.dailyLog[.lowIntensity] == RewardAmount(xp: 2, coins: 0))
    #expect(money.dailyLog[.highIntensity] == RewardAmount(xp: 5, coins: 0))
    #expect(money.weekAnchorWeekday == .monday)
    #expect(money.weekMinCovered == 5)
    #expect(money.coverageThreshold == Thousandths(600))
    #expect(money.closeGraceDays == 3)
    #expect(money.pendingHoldDays == 7)
  }

  @Test func shouldScaleTheStandardCloseTableByHalfAndOneAndAHalfRoundingHalvesUp() throws {
    let close = try #require(Self.money).close
    let expected: [IntensityMode: [BudgetCloseOutcome: MoneyCloseEffect]] = [
      .standard: [
        .withinTypical: Self.reward(40, 8), .within: Self.reward(20, 3), .over10: Self.penalty(15, 850, 7), .over25: Self.penalty(30, 750, 14),
        .overMore: Self.penalty(60, 600, 30), .unscored: Self.penalty(60, 600, 30),
      ],
      .lowIntensity: [
        .withinTypical: Self.reward(20, 4), .within: Self.reward(10, 2), .over10: Self.penalty(8, 850, 4), .over25: Self.penalty(15, 750, 7),
        .overMore: Self.penalty(30, 600, 15), .unscored: Self.penalty(30, 600, 15),
      ],
      .highIntensity: [
        .withinTypical: Self.reward(60, 12), .within: Self.reward(30, 5), .over10: Self.penalty(23, 850, 11), .over25: Self.penalty(45, 750, 21),
        .overMore: Self.penalty(90, 600, 45), .unscored: Self.penalty(90, 600, 45),
      ],
    ]
    for mode in IntensityMode.allCases {
      for outcome in BudgetCloseOutcome.allCases { #expect(close[mode][outcome] == expected[mode]?[outcome], "\(mode.rawValue) \(outcome.rawValue)") }
    }
  }

  @Test func shouldNeverMakeNotLoggingCheaperThanOverspending() throws {
    let close = try #require(Self.money).close
    for mode in IntensityMode.allCases {
      guard case .penalty(let unscoredFine, let unscored) = close[mode][.unscored] else {
        Issue.record("\(mode.rawValue): unscored must be a penalty")
        continue
      }
      var previous: (fine: Int, debuff: MoneyDebuff)?
      for outcome in [BudgetCloseOutcome.over10, .over25, .overMore] {
        guard case .penalty(let fine, let debuff) = close[mode][outcome] else {
          Issue.record("\(mode.rawValue) \(outcome.rawValue) must be a penalty")
          continue
        }
        #expect(unscoredFine >= fine && unscored.multiplier <= debuff.multiplier && unscored.days >= debuff.days, "\(mode.rawValue) \(outcome.rawValue)")
        if let previous { #expect(fine > previous.fine && debuff.multiplier < previous.debuff.multiplier && debuff.days > previous.debuff.days) }
        previous = (fine, debuff)
      }
      guard case .reward(let typical) = close[mode][.withinTypical], case .reward(let within) = close[mode][.within] else {
        Issue.record("\(mode.rawValue): staying within the limit must be a reward")
        continue
      }
      #expect(typical.xp > within.xp && typical.coins > within.coins)
    }
  }

  @Test func shouldScaleGoalMilestonesAndPurchasesLikeTheCloseTable() throws {
    let money = try #require(Self.money)
    let milestones: [IntensityMode: [GoalMilestone: RewardAmount]] = [
      .standard: [.p25: RewardAmount(xp: 10, coins: 0), .p50: RewardAmount(xp: 10, coins: 0), .p75: RewardAmount(xp: 15, coins: 0), .p100: RewardAmount(xp: 30, coins: 5)],
      .lowIntensity: [.p25: RewardAmount(xp: 5, coins: 0), .p50: RewardAmount(xp: 5, coins: 0), .p75: RewardAmount(xp: 8, coins: 0), .p100: RewardAmount(xp: 15, coins: 3)],
      .highIntensity: [.p25: RewardAmount(xp: 15, coins: 0), .p50: RewardAmount(xp: 15, coins: 0), .p75: RewardAmount(xp: 23, coins: 0), .p100: RewardAmount(xp: 45, coins: 8)],
    ]
    let purchases: [IntensityMode: RewardAmount] = [
      .standard: RewardAmount(xp: 30, coins: 5), .lowIntensity: RewardAmount(xp: 15, coins: 3), .highIntensity: RewardAmount(xp: 45, coins: 8),
    ]
    for mode in IntensityMode.allCases {
      for milestone in GoalMilestone.allCases {
        #expect(money.milestones[mode][milestone] == milestones[mode]?[milestone], "\(mode.rawValue) \(milestone.rawValue)")
      }
      #expect(money.goalPurchase[mode][.within] == purchases[mode], "\(mode.rawValue)")
      #expect(money.goalPurchase[mode][.over] == .zero, "\(mode.rawValue)")
    }
  }

  @Test func shouldFloorDebuffedXP() {
    #expect(Ruleset.debuffed(xp: 10, multiplier: Thousandths(850)) == 8)
    #expect(Ruleset.debuffed(xp: 25, multiplier: Thousandths(600)) == 15)
    #expect(Ruleset.debuffed(xp: 3, multiplier: Thousandths(750)) == 2)
    #expect(Ruleset.debuffed(xp: 1, multiplier: Thousandths(600)) == 0)
    #expect(Ruleset.debuffed(xp: 40, multiplier: Thousandths(1000)) == 40)
    #expect(Ruleset.debuffed(xp: 0, multiplier: Thousandths(600)) == 0)
    #expect(Ruleset.debuffed(xp: .max, multiplier: Thousandths(2000)) == .max)
  }
}
