import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Memoir money replay", TestTimeLimit.quick)
struct MoneyReplayTests {
  private typealias Fixture = ReplayFixture

  private static func stamped(_ number: Int, _ body: MemoirCommandBody, at instant: String) throws -> MemoirCommand {
    try Fixture.command(number, body, at: instant, rulesetVersion: Ruleset.v2.version)
  }

  private static func close(_ number: Int, _ outcome: BudgetCloseOutcome, budget: UUID = CommandSamples.budget, at instant: String) throws -> MemoirCommand {
    try Self.stamped(
      number, .budgetClosePeriod(try BudgetPeriodClose(budgetId: budget, periodStart: try MemoirStoreFixture.date("2026-02-01"), outcome: outcome, deposited: false)),
      at: instant)
  }

  private static func date(_ text: String) throws -> LocalDate { try MemoirStoreFixture.date(text) }

  /// Steps each command in turn, clocked after everything the state has taken.
  private static func extend(_ state: ReplayState, with commands: [MemoirCommand], from wall: Int64) throws -> ReplayState {
    var state = state
    for (index, command) in commands.enumerated() { Replay.step(try Fixture.entry(command, wall: wall + Int64(index)), to: &state) }
    return state
  }

  @Test func shouldDebuffARecoveryCompletionAsAQuestCompletion() throws {
    let create = try Fixture.command(1, Fixture.create(schedule: try Fixture.routine()), at: "2026-03-01T06:00:00Z")
    let recover = try Self.stamped(3, .recoveryComplete(RecoveryCompletion()), at: "2026-03-02T09:00:00Z")
    let debuffed = Replay.run(try Fixture.entries([create, try Self.close(2, .overMore, at: "2026-03-02T07:00:00Z"), recover]))
    let plain = Replay.run(try Fixture.entries([create, try Self.stamped(2, .moneyNoSpend(NoSpendDay(date: try Self.date("2026-03-02"))), at: "2026-03-02T07:00:00Z"), recover]))
    let recovery = try #require(plain.compassion.recoveries[try Self.date("2026-03-02")])
    let key = "recovery_completed_\(recovery.id.lowercasedString)"
    #expect(plain.hero.event(forKey: key)?.xpDelta == 5)
    #expect(debuffed.hero.event(forKey: key)?.xpDelta == 3, "floor(5 x 0.6)")
  }

  @Test func shouldDebuffADayCoveredLateAfterTheDebuffedDayClosed() throws {
    let commands = [
      try Self.close(1, .over10, at: "2026-03-04T09:00:00Z"),
      try Self.stamped(2, .moneyNoSpend(NoSpendDay(date: try Self.date("2026-03-10"))), at: "2026-03-12T09:00:00Z"),
    ]
    let state = Replay.run(try Fixture.entries(commands))
    #expect(state.hero.event(forKey: "moneylog_2026-03-10")?.xpDelta == 2, "floor(3 x 0.85): the debuff ending on 10 March outlives that day's close by the late window")
    #expect(state.money.debuffs.count == 1)
    let later = Replay.run(
      try Fixture.entries(commands), through: IssueStamp(instantMillis: try Fixture.millis("2026-03-14T09:00:00Z"), utcOffsetMinutes: 0, issuedOn: try Self.date("2026-03-14")))
    #expect(later.money.debuffs.isEmpty, "the close of 13 March, three days after its end, drops it")
    #expect(later.money.closes.count == 1, "the close itself stays")
  }

  @Test func shouldExtendTheMoneyStreakOnlyFromTheWeekBefore() throws {
    let monday = try Self.date("2026-03-02")
    var state = ReplayState.initial
    state.money.lastActivityDay = monday
    for offset in 0..<5 { state.money.coveredDays[try #require(monday.adding(days: offset))] = MoneyCoverage(source: .noSpend, command: CommandSamples.record) }
    let tuesday = try Self.date("2026-03-10")

    var following = state
    following.money.weekStreak = 3
    following.money.lastSettledWeekStart = try Self.date("2026-02-23")
    following.settleMoney(closing: tuesday, ruleset: .v2)
    #expect(following.money.weekStreak == 4 && following.money.lastSettledWeekStart == monday)

    var gapped = state
    gapped.money.weekStreak = 3
    gapped.money.lastSettledWeekStart = try Self.date("2026-02-09")
    gapped.settleMoney(closing: tuesday, ruleset: .v2)
    #expect(gapped.money.weekStreak == 1, "a week the walk never settled breaks the run")

    var underV1 = state
    underV1.settleMoney(closing: tuesday, ruleset: .v1)
    #expect(underV1.money.lastSettledWeekStart == nil, "a day closed under v1 settles nothing")

    var notTuesday = state
    notTuesday.settleMoney(closing: try Self.date("2026-03-11"), ruleset: .v2)
    #expect(notTuesday.money.lastSettledWeekStart == nil)
  }

  @Test func shouldCreditNothingAndChangeNothingForADuplicateOrARefusal() throws {
    let day = try Self.date("2026-03-05")
    let base = [try Self.stamped(1, .moneyNoSpend(NoSpendDay(date: day)), at: "2026-03-05T09:00:00Z")]
    let before = Replay.run(try Fixture.entries(base))
    let duplicate = try Self.stamped(2, .moneyNoSpend(NoSpendDay(date: day)), at: "2026-03-07T09:00:00Z")
    let stale = try Self.stamped(3, .moneyNoSpend(NoSpendDay(date: day)), at: "2026-03-08T09:00:00Z")
    let after = Replay.run(try Fixture.entries(base + [duplicate, stale]))
    #expect(after.outcomes[duplicate.id] == .superseded)
    #expect(after.outcomes[stale.id] == .refused(.outsideLoggingWindow(day)))
    #expect(after.hero == before.hero && after.money.coveredDays == before.money.coveredDays)
    #expect(after.money.lastActivityDay == day, "neither the duplicate nor the refusal counts as activity")
    let refusal = ReplayRefusal.outsideLoggingWindow(day)
    #expect(refusal.code == "memoir_replay.outside_logging_window")
    #expect(refusal.referenceCode == nil)
  }

  @Test func shouldFlipAnAppliedCloseToSupersededWhenAnEarlierOneArrivesLate() throws {
    let later = try Self.close(1, .within, at: "2026-03-05T09:00:00Z")
    let earlier = try Self.close(2, .overMore, at: "2026-03-04T09:00:00Z")
    let first = Replay.run([try Fixture.entry(later, wall: 20)])
    #expect(first.outcomes[later.id] == .applied)
    #expect(throws: ReplayOrderError.self) { try Replay.extend(first, with: [try Fixture.entry(earlier, wall: 10)]) }
    let replayed = Replay.run([try Fixture.entry(later, wall: 20), try Fixture.entry(earlier, wall: 10)])
    #expect(replayed.outcomes[later.id] == .superseded && replayed.outcomes[earlier.id] == .applied)
    #expect(replayed.money.closes.values.map(\.command) == [earlier.id])
    #expect(replayed.hero.event(forKey: "moneyclose_\(CommandSamples.budget.lowercasedString)_2026-02-01") == nil, "the superseded reward never lands")
    let fifth = try Self.date("2026-03-05")
    #expect(replayed.money.savingStreak == 0 && replayed.money.debuffMultiplier(on: fifth) == Thousandths(600))
  }

  @Test func shouldNeverRefuseAFineAndRecordWhatTheBalanceAllowed() throws {
    var ledger = HeroLedger.empty
    _ = ledger.credit([GrantIntent(key: "seed", type: .coinGrant, date: try Self.date("2026-03-01"), coinsDelta: 7)], ruleset: .v2)
    let fine = GrantIntent(key: "moneyfine_x", type: .moneyFine, date: try Self.date("2026-03-02"))
    #expect(ledger.fine(fine, coins: 15, ruleset: .v2) == 7)
    #expect(ledger.coins == 0 && ledger.event(forKey: "moneyfine_x")?.coinsDelta == -7)
    #expect(ledger.fine(fine, coins: 15, ruleset: .v2) == 7, "the same key fines once")
    #expect(ledger.fine(GrantIntent(key: "moneyfine_y", type: .moneyFine, date: try Self.date("2026-03-03")), coins: 30, ruleset: .v2) == 0)
    #expect(try JSONDecoder().decode(HeroLedger.self, from: try JSONEncoder().encode(ledger)) == ledger, "a fined trail still sums to its totals")
  }

  /// Not logging must never be cheaper than overspending: from any balance, intensity and earlier debuff, an unscored close leaves no more coins and no
  /// more XP from the same later grants than any over close, and its debuff is at least as strong on every later day.
  @Test(TestTimeLimit.property) func shouldNeverMakeAnUnscoredCloseCheaperThanAnOverClose() throws {
    try forAll(iterations: 120) { generator in
      let mode = generator.pick(from: IntensityMode.allCases)
      var base = Replay.run(try Fixture.entries([try Self.stamped(1, .accountSetIntensityMode(IntensityModeChange(mode: mode)), at: "2026-03-01T09:00:00Z")]))
      base.hero.coins = generator.int(in: 0...150)
      var setup = [MemoirCommand]()
      if generator.chance(0.5) {
        setup.append(try Self.close(2, generator.pick(from: [.over10, .over25, .overMore]), budget: CommandSamples.goal, at: "2026-03-02T09:00:00Z"))
      }
      let prepared = try Self.extend(base, with: setup, from: 10)
      let laterDays = (0..<generator.int(in: 3...12)).map { _ in generator.int(in: 3...45) }
      func run(_ outcome: BudgetCloseOutcome) throws -> ReplayState {
        var commands = [try Self.close(3, outcome, at: "2026-03-03T09:00:00Z")]
        for (index, offset) in laterDays.sorted().enumerated() {
          let day = try #require(try Self.date("2026-03-01").adding(days: offset))
          commands.append(try Self.stamped(100 + index, .sideQuestLog(SideQuestEntry(id: MemoirStoreFixture.commandID(500 + index), date: day)), at: "\(day.isoString)T10:00:00Z"))
        }
        return try Self.extend(prepared, with: commands, from: 100)
      }
      let unscored = try run(.unscored)
      for outcome in [BudgetCloseOutcome.over10, .over25, .overMore] {
        let over = try run(outcome)
        #expect(unscored.hero.coins <= over.hero.coins, "\(mode.rawValue) \(outcome.rawValue) coins")
        #expect(unscored.hero.totalXP <= over.hero.totalXP, "\(mode.rawValue) \(outcome.rawValue) XP")
        for offset in 2...50 {
          let day = try #require(try Self.date("2026-03-01").adding(days: offset))
          let strength = { (state: ReplayState) in state.money.debuffMultiplier(on: day)?.thousandths ?? 1000 }
          #expect(strength(unscored) <= strength(over), "\(mode.rawValue) \(outcome.rawValue) on \(day)")
        }
      }
    }
  }
}
