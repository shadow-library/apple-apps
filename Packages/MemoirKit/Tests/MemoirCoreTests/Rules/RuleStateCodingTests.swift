import Foundation
import ShadowCore
import Testing

@testable import MemoirCore

@Suite("Memoir rule state coding", TestTimeLimit.quick)
struct RuleStateCodingTests {
  private static func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
  }

  private static func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(json.utf8))
  }

  @Test func shouldRoundTripEveryRuleState() throws {
    let streak = StreakState(currentDays: 4, longestDays: 9, shields: 1, completionsTowardShield: 3, pendingShieldGrant: 1)
    #expect(try Self.roundTrip(streak) == streak)
    let comeback = ComebackDayState(armed: true, fires: 1, armedViaRecovery: true)
    #expect(try Self.roundTrip(comeback) == comeback)
    let crown = Ruleset.v1.forfeitCrownSlice(Ruleset.v1.endowCrown(weights: [Halves(3), Halves(2)]), weight: Halves(2))
    #expect(try Self.roundTrip(crown) == crown)
    var counters = ProgressCounters()
    counters.totalXP = 120
    counters.level = 2
    counters.stats[.mind] = 4
    counters.completionsByStrictness[.goal] = 7
    counters.activeDays = 3
    #expect(try Self.roundTrip(counters) == counters)
  }

  @Test func shouldRefuseStatesTheRulesCannotProduce() throws {
    #expect(throws: DecodingError.self) {
      try Self.decode(StreakState.self, #"{"currentDays":5,"longestDays":4,"shields":0,"completionsTowardShield":0,"pendingShieldGrant":0}"#)
    }
    #expect(throws: DecodingError.self) {
      try Self.decode(StreakState.self, #"{"currentDays":0,"longestDays":0,"shields":-1,"completionsTowardShield":0,"pendingShieldGrant":0}"#)
    }
    #expect(throws: DecodingError.self) { try Self.decode(ComebackDayState.self, #"{"armed":true,"fires":-1,"armedViaRecovery":false}"#) }
    #expect(throws: DecodingError.self) { try Self.decode(ComebackDayState.self, #"{"armed":false,"fires":2,"armedViaRecovery":false}"#) }
    #expect(throws: DecodingError.self) { try Self.decode(ComebackDayState.self, #"{"armed":false,"fires":3,"armedViaRecovery":true}"#) }
    #expect(try Self.decode(ComebackDayState.self, #"{"armed":false,"fires":2,"armedViaRecovery":true}"#).fires == 2)
    #expect(throws: DecodingError.self) {
      try Self.decode(
        CrownDayState.self, #"{"endowedHalves":2,"forfeitedHalves":0,"grantedXP":-4,"grantedCoins":1,"remainingXP":0,"remainingCoins":0}"#)
    }
    #expect(throws: DecodingError.self) {
      try Self.decode(
        CrownDayState.self, #"{"endowedHalves":2,"forfeitedHalves":3,"grantedXP":4,"grantedCoins":1,"remainingXP":0,"remainingCoins":0}"#)
    }
    #expect(throws: DecodingError.self) {
      try Self.decode(
        CrownDayState.self, #"{"endowedHalves":2,"forfeitedHalves":0,"grantedXP":4,"grantedCoins":1,"remainingXP":5,"remainingCoins":0}"#)
    }
    var counters = ProgressCounters()
    counters.level = 0
    #expect(throws: DecodingError.self) { try Self.roundTrip(counters) }
    #expect(throws: DecodingError.self) { try Self.decode(RuleTable<StatAffinity, Int>.self, #"{"discipline":1,"body":1,"wealth":1}"#) }
  }

  @Test func shouldRoundTripMoneyStateAndRefuseACloseThatIsBothOrNeither() throws {
    let day = try MemoirStoreFixture.date("2026-03-04")
    let span = MoneyDebuffSpan(from: day, through: try #require(day.adding(days: 6)), multiplier: Thousandths(850), command: CommandSamples.record)
    var money = MoneyState.empty
    money.coveredDays[day] = MoneyCoverage(source: .expense, command: CommandSamples.record)
    money.closes[MoneyCloseKey(budget: CommandSamples.budget, periodStart: try MemoirStoreFixture.date("2026-02-01"))] = MoneyClose(
      command: CommandSamples.record, outcome: .over10, deposited: false, closedOn: day, result: .fined(intended: 15, applied: 4, debuff: span))
    money.closes[MoneyCloseKey(budget: CommandSamples.goal, periodStart: try MemoirStoreFixture.date("2026-02-01"))] = MoneyClose(
      command: CommandSamples.record, outcome: .within, deposited: true, closedOn: day, result: .rewarded(RewardAmount(xp: 20, coins: 3)))
    money.milestones = [GoalMilestoneKey(goal: CommandSamples.goal, milestone: .p50)]
    money.goalsBought = [CommandSamples.goal]
    money.debuffs = [span]
    money.weekStreak = 2
    money.savingStreak = 1
    money.lastActivityDay = day
    money.lastSettledWeekStart = try MemoirStoreFixture.date("2026-02-23")
    #expect(try Self.roundTrip(money) == money)
    #expect(try MemoirReconciler.canonicalJSON(money) == (try MemoirReconciler.canonicalJSON(Self.roundTrip(money))), "the encoding is canonical")

    let id = CommandSamples.record.lowercasedString
    let reward = #"{"command":"\#(id)","outcome":"within","deposited":true,"closedOn":"2026-03-04","reward":{"xp":20,"coins":3}"#
    #expect(try Self.decode(MoneyClose.self, reward + "}").result == .rewarded(RewardAmount(xp: 20, coins: 3)))
    #expect(throws: DecodingError.self) { try Self.decode(MoneyClose.self, reward + #","fine":15,"fineApplied":4}"#) }
    #expect(throws: DecodingError.self) { try Self.decode(MoneyClose.self, #"{"command":"\#(id)","outcome":"within","deposited":true,"closedOn":"2026-03-04"}"#) }
  }

  @Test func shouldBuildOnlyAConsistentCrownDay() {
    let granted = RewardAmount(xp: 10, coins: 2)
    #expect(CrownDayState(endowed: Halves(5), forfeited: Halves(2), granted: granted, remaining: RewardAmount(xp: 6, coins: 1)) != nil)
    #expect(CrownDayState(endowed: Halves(5), forfeited: Halves(6), granted: granted, remaining: .zero) == nil)
    #expect(CrownDayState(endowed: Halves(5), forfeited: Halves(-1), granted: granted, remaining: .zero) == nil)
    #expect(CrownDayState(endowed: Halves(5), forfeited: .zero, granted: granted, remaining: RewardAmount(xp: 11, coins: 0)) == nil)
    #expect(CrownDayState(endowed: Halves(5), forfeited: .zero, granted: granted, remaining: RewardAmount(xp: 0, coins: -1)) == nil)
    #expect(CrownDayState(endowed: Halves(5), forfeited: .zero, granted: RewardAmount(xp: -1, coins: 0), remaining: .zero) == nil)
    #expect(CrownDayState(endowed: Halves(5), forfeited: .zero, granted: RewardAmount(xp: 0, coins: -2), remaining: .zero) == nil)
  }
}
