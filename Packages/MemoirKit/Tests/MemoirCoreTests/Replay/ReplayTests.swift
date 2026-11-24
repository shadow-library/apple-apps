import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir replay", TestTimeLimit.quick)
struct ReplayTests {
  private typealias Fixture = ReplayFixture

  private static func createAndComplete() throws -> [MemoirCommand] {
    [
      try Fixture.command(1, Fixture.create(schedule: try Fixture.routine()), at: "2026-03-01T06:00:00Z"),
      try Fixture.command(2, .questComplete(try Fixture.occurrence("2026-03-10")), at: "2026-03-10T08:10:00Z"),
    ]
  }

  @Test func shouldOrderByClockThenId() throws {
    let first = try Fixture.command(5, .receiptScan(ReceiptScan()), at: "2026-03-10T08:00:00Z")
    let second = try Fixture.command(4, .receiptScan(ReceiptScan()), at: "2026-03-10T08:00:00Z")
    let tied = [try Fixture.entry(first, wall: 7), try Fixture.entry(second, wall: 7)]
    #expect(Replay.ordered(tied).map(\.ref) == [second.ref, first.ref])
    let clocked = [try Fixture.entry(second, wall: 9), try Fixture.entry(first, wall: 8)]
    #expect(Replay.ordered(clocked).map(\.ref) == [first.ref, second.ref])
  }

  @Test func shouldGiveTheSameStateForAnyInputOrder() throws {
    let entries = try Fixture.entries(
      Self.createAndComplete() + [try Fixture.command(3, .questSkip(QuestBreak(occurrence: try Fixture.occurrence("2026-03-10"))), at: "2026-03-10T08:11:00Z")])
    #expect(Fixture.fold(entries) == Fixture.fold(entries.reversed()))
    #expect(Fixture.fold(entries).hero.totalXP == Ruleset.v1.reward.baseXP[.routine][.onTime])
  }

  @Test func shouldTakeACommandInOnlyOnce() throws {
    let entries = try Fixture.entries(Self.createAndComplete())
    let once = Fixture.fold(entries)
    var twice = once
    Replay.apply(entries[1], to: &twice)
    #expect(twice == once)
    #expect(Fixture.fold(entries + [try Fixture.entry(Self.createAndComplete()[1], wall: 99, replica: Fixture.replicaB)]) == once)
  }

  @Test func shouldLetTheFirstTerminalActionInClockOrderWin() throws {
    let occurrence = try Fixture.occurrence("2026-03-10")
    let create = try Fixture.command(1, Fixture.create(schedule: try Fixture.routine()), at: "2026-03-01T06:00:00Z")
    let complete = try Fixture.command(2, .questComplete(occurrence), at: "2026-03-10T08:10:00Z")
    let skip = try Fixture.command(3, .questSkip(QuestBreak(occurrence: occurrence, reasonTag: .travel)), at: "2026-03-10T08:05:00Z")
    let completeFirst = Fixture.fold([try Fixture.entry(create, wall: 1), try Fixture.entry(complete, wall: 2), try Fixture.entry(skip, wall: 3, replica: Fixture.replicaB)])
    #expect(completeFirst.logs[occurrence]?.state == .completed)
    #expect(completeFirst.outcomes[skip.id] == .superseded)
    #expect(completeFirst.progression.counters.reasonTaggedEvents == 0)
    let skipFirst = Fixture.fold([try Fixture.entry(create, wall: 1), try Fixture.entry(complete, wall: 3), try Fixture.entry(skip, wall: 2, replica: Fixture.replicaB)])
    #expect(skipFirst.logs[occurrence]?.state == .skipped)
    #expect(skipFirst.outcomes[complete.id] == .superseded)
    #expect(skipFirst.hero.totalXP == 0)
  }

  @Test func shouldLetAUserOutcomeReplaceASystemMissButNotTheReverse() throws {
    let occurrence = try Fixture.occurrence("2026-03-08")
    var state = Fixture.fold(try Fixture.entries([try Fixture.command(1, Fixture.create(schedule: try Fixture.routine()), at: "2026-03-01T06:00:00Z")]))
    let miss = QuestLogEntry(
      id: MemoirStoreFixture.commandID(900), state: .missed, xpAwarded: 0, coinsAwarded: 0, statAffinity: .body, strictness: .routine, intensityModeAtLog: .standard,
      crownSliceWeight: Halves(2), rulesetVersion: 1, createdAtMillis: try Fixture.millis("2026-03-09T00:00:00Z"))
    state.logs[occurrence] = miss
    let late = try Fixture.command(2, .questComplete(occurrence), at: "2026-03-10T08:00:00Z")
    Replay.apply(try Fixture.entry(late, wall: 2), to: &state)
    let log = try #require(state.logs[occurrence])
    #expect(log.state == .late)
    #expect(log.id == miss.id)
    #expect(log.createdAtMillis == miss.createdAtMillis)
    #expect(state.hero.event(forKey: "\(miss.id.lowercasedString)_xp")?.xpDelta == Ruleset.v1.reward.baseXP[.routine][.day2])
    #expect(
      state.upsertTerminal(
        QuestLogWrite(
          id: miss.id, state: .missed, statAffinity: .body, strictness: .routine, intensityModeAtLog: .standard, crownSliceWeight: Halves(2), rulesetVersion: 1, atMillis: 0),
        at: occurrence) == nil)
  }

  @Test func shouldWithdrawAPurchaseTheMergedBalanceNoLongerCovers() throws {
    let ember = try Fixture.command(1, .cosmeticPurchase(.accentEmber), at: "2026-03-10T08:00:00Z")
    let frost = try Fixture.command(2, .cosmeticPurchase(.accentFrost), at: "2026-03-10T08:00:30Z")
    for (first, second, cosmetic) in [(ember, frost, CosmeticID.accentFrost), (frost, ember, .accentEmber)] {
      let merged = Fixture.fold([try Fixture.entry(first, wall: 1), try Fixture.entry(second, wall: 2, replica: Fixture.replicaB)], from: Fixture.state(coins: 120))
      #expect(merged.hero.coins == 20)
      #expect(merged.outcomes[first.id] == .applied)
      #expect(merged.outcomes[second.id] == .refused(.notEnoughCoins(balance: 20, required: 100)))
      #expect(merged.notices == [.purchaseWithdrawn(command: second.id, cosmetic: cosmetic, balance: 20, price: 100)])
      #expect(merged.progression.cosmetics[cosmetic] == nil)
      #expect(merged.hero.events.count == 1)
    }
  }

  @Test func shouldKeepTheStateBeforeARefusedCommand() throws {
    var state = Fixture.fold(try Fixture.entries(Self.createAndComplete()))
    let before = state
    let unknown = try Fixture.command(3, .questComplete(try Fixture.occurrence("2026-03-10", of: Fixture.secondQuest)), at: "2026-03-10T09:00:00Z")
    Replay.apply(try Fixture.entry(unknown, wall: 3), to: &state)
    #expect(state.outcomes[unknown.id] == .refused(.questNotFound))
    var withoutOutcome = state
    withoutOutcome.outcomes[unknown.id] = nil
    withoutOutcome.commandCount -= 1
    #expect(withoutOutcome == before)
  }

  @Test func shouldHaltOnACommandOfANewerType() throws {
    let millis = try Fixture.millis("2026-03-10T09:00:00Z")
    let future = try MemoirCommand(
      id: MemoirStoreFixture.commandID(3), payload: try CommandPayload(["flag": .bool(true)], type: try CommandType("future.feature")), instantMillis: millis,
      utcOffsetMinutes: 0, issuedOn: try MemoirCommand.localDate(instantMillis: millis, utcOffsetMinutes: 0), rulesetVersion: 1)
    let later = try Fixture.command(4, .questComplete(try Fixture.occurrence("2026-03-11")), at: "2026-03-11T09:00:00Z")
    let entries = try Fixture.entries(Self.createAndComplete() + [future, later])
    let state = Fixture.fold(entries)
    #expect(state.halt == .unknownCommandType(command: future.id, type: "future.feature"))
    #expect(state.outcomes[later.id] == nil)
    #expect(state.hero.totalXP == Fixture.fold(Array(entries.prefix(2))).hero.totalXP)
  }

  @Test func shouldHaltOnARulesetThisAppLacks() throws {
    let newer = try Fixture.command(3, .questComplete(try Fixture.occurrence("2026-03-11")), at: "2026-03-11T08:10:00Z", rulesetVersion: 3)
    let state = Fixture.fold(try Fixture.entries(Self.createAndComplete() + [newer]))
    #expect(state.halt == .rulesetUnavailable(command: newer.id, version: 3))
    #expect(state.logs[try Fixture.occurrence("2026-03-11")] == nil)
    #expect(state.highestRulesetVersion == 1)
  }

  private static func moneyBodies() throws -> [MemoirCommandBody] {
    let date = try MemoirStoreFixture.date("2026-03-10")
    return [
      .moneyNoSpend(NoSpendDay(date: date)),
      .expenseCreate(ExpenseCreation(id: CommandSamples.record, occurredOn: date)),
      .budgetClosePeriod(try BudgetPeriodClose(budgetId: CommandSamples.budget, periodStart: try MemoirStoreFixture.date("2026-02-01"), outcome: .overMore, deposited: false)),
      .goalMilestone(GoalMilestoneReached(goalId: CommandSamples.goal, milestone: .p100)),
      .goalBought(GoalPurchase(goalId: CommandSamples.goal, outcome: .within)),
    ]
  }

  @Test func shouldRecordACommandStampedBelowItsBodysRulesetAsRefusedAndReplayOn() throws {
    let stale = try Self.moneyBodies().enumerated().map { index, body in
      try Fixture.command(10 + index, body, at: "2026-03-10T07:0\(index):00Z", rulesetVersion: 1)
    }
    let update = try Fixture.command(20, .expenseUpdate(RecordReference(id: CommandSamples.record)), at: "2026-03-10T07:30:00Z")
    let later = try Fixture.command(3, .questComplete(try Fixture.occurrence("2026-03-11")), at: "2026-03-11T08:10:00Z")
    let commands = try Self.createAndComplete() + stale + [update, later]
    let state = Replay.run(try Fixture.entries(commands))
    #expect(state.halt == nil)
    for command in stale {
      #expect(state.outcomes[command.id] == .refused(.needsNewerRuleset(minimum: 2)), "\(command.type)")
    }
    #expect(state.outcomes[update.id] == .refused(.expenseNotFound), "a refused creation names no expense")
    #expect(state.outcomes[later.id] == .applied)
    #expect(state.logs[try Fixture.occurrence("2026-03-11")]?.state == .completed)
    let without = Replay.run(try Fixture.entries(Self.createAndComplete() + [later]))
    #expect(state.hero == without.hero && state.logs == without.logs && state.days == without.days, "refusing changes nothing else")
    #expect(ReplayRefusal.needsNewerRuleset(minimum: 2).code == "memoir_replay.needs_newer_ruleset")
    #expect(ReplayRefusal.needsNewerRuleset(minimum: 2).referenceCode == nil)
  }

  @Test func shouldApplyEveryCommandStampedWithMoneyRules() throws {
    let stamped = try Self.moneyBodies() + [.questComplete(try Fixture.occurrence("2026-03-11")), .receiptScan(ReceiptScan())]
    let tenth = try MemoirStoreFixture.date("2026-03-10")
    for (index, body) in stamped.enumerated() {
      let command = try Fixture.command(10 + index, body, at: "2026-03-11T08:10:00Z", rulesetVersion: 2)
      let later = try Fixture.command(30, .receiptScan(ReceiptScan()), at: "2026-03-11T09:00:00Z")
      let state = Replay.run(try Fixture.entries(Self.createAndComplete() + [command, later]))
      #expect(state.halt == nil, "\(body.kind.rawValue)")
      #expect(state.outcomes[later.id] == .applied && state.outcomes[command.id] != nil, "\(body.kind.rawValue)")
      #expect(state.highestRulesetVersion == 2 && state.days[tenth]?.rulesetVersion == 2, "a day closes under v2 once seen")
    }
  }

  @Test func shouldHaltAtAnUnreadableItemInClockOrder() async throws {
    let store = try VaultStore.open(.inMemory, registry: MemoirSchema.mainRegistry)
    let commands = try Self.createAndComplete()
    let unreadable = MemoirCommand.ref(MemoirStoreFixture.commandID(50))
    let after = try Fixture.command(60, .questComplete(try Fixture.occurrence("2026-03-11")), at: "2026-03-11T08:10:00Z")
    try await store.write { transaction in
      for command in commands { try command.append(in: &transaction) }
      _ = try transaction.append(unreadable, item: ["type": .string("quest.complete")])
      try after.append(in: &transaction)
    }
    let loaded = try await store.read { transaction in try Replay.commands(in: transaction) }
    #expect(loaded.map(\.ref) == commands.map(\.ref) + [unreadable, after.ref])
    let state = Fixture.fold(loaded)
    #expect(state.halt == .unreadableCommand(unreadable))
    #expect(state.outcomes[commands[1].id] == .applied)
    #expect(state.outcomes[after.id] == nil)
  }

  @Test func shouldCarryEachGrantIntoTheNextAndRefuseASpendTheBalanceNoLongerHolds() throws {
    var ledger = HeroLedger.empty
    ledger.coins = 50
    let date = try MemoirStoreFixture.date("2026-03-01")
    let outcomes = try ledger.grant(
      [
        GrantIntent(key: "a", type: .crownForfeit, date: date, xpDelta: 10, coinsDelta: 5, statAffinity: .body, statDelta: 1),
        GrantIntent(key: "b", type: .crownForfeit, date: date, xpDelta: 20, coinsDelta: -15, statAffinity: .body, statDelta: 2),
        GrantIntent(key: "c", type: .crownForfeit, date: date, xpDelta: 30, statAffinity: .mind, statDelta: 1),
      ], ruleset: .v1)
    #expect(outcomes.allSatisfy { $0.isApplied })
    #expect((ledger.totalXP, ledger.coins, ledger.stats[.body], ledger.stats[.mind]) == (60, 40, 3, 1))

    var spending = HeroLedger.empty
    spending.coins = 50
    #expect(throws: ReplayRefusal.notEnoughCoins(balance: 20, required: 30)) {
      try spending.grant(
        [GrantIntent(key: "spend-1", type: .coinSpend, date: date, coinsDelta: -30), GrantIntent(key: "spend-2", type: .coinSpend, date: date, coinsDelta: -30)],
        ruleset: .v1)
    }

    let again = try ledger.grant(
      [GrantIntent(key: "a", type: .crownForfeit, date: date, xpDelta: 99), GrantIntent(key: "fresh", type: .crownForfeit, date: date, xpDelta: 4)], ruleset: .v1)
    #expect(again.map(\.isApplied) == [false, true])
    #expect(ledger.totalXP == 64)
  }

  @Test func shouldAppendEveryLevelCrossed() throws {
    var ledger = HeroLedger.empty
    let date = try MemoirStoreFixture.date("2026-03-01")
    let outcomes = try ledger.grant([GrantIntent(key: "big", type: .crownBanked, date: date, xpDelta: Ruleset.v1.level.xpThreshold(forLevel: 4))], ruleset: .v1)
    #expect(outcomes.first?.event.levelAfter == 4)
    #expect(ledger.events.map(\.key) == ["big", "levelup_2", "levelup_3", "levelup_4"])
    #expect(ledger.events.dropFirst().map(\.levelAfter) == [2, 3, 4])
    _ = try ledger.grant([GrantIntent(key: "huge", type: .crownBanked, date: date, xpDelta: .max)], ruleset: .v1)
    #expect(ledger.totalXP == .max)
    #expect(ledger.level == Ruleset.v1.level.maxLevel)
    _ = try ledger.grant([GrantIntent(key: "more", type: .crownBanked, date: date, xpDelta: 1)], ruleset: .v1)
    #expect(ledger.totalXP == .max)
  }

  @Test func shouldStageTheZoneAndIntensityUntilTheWalkPreparesADayAndApplyTheThresholdAtOnce() throws {
    let commands = [
      try Fixture.command(1, .accountSetTimeZone(try TimeZoneChange(identifier: "Europe/Berlin")), at: "2026-03-01T08:00:00Z"),
      try Fixture.command(2, .accountSetTimeZone(try TimeZoneChange(identifier: "Asia/Tokyo")), at: "2026-03-05T08:00:00Z"),
      try Fixture.command(3, .accountSetIntensityMode(IntensityModeChange(mode: .lowIntensity)), at: "2026-03-05T08:00:00Z"),
      try Fixture.command(4, .accountSetIntensityMode(IntensityModeChange(mode: .highIntensity)), at: "2026-03-05T09:00:00Z"),
      try Fixture.command(5, .accountSetReturnerThreshold(try ReturnerThresholdChange(days: 3)), at: "2026-03-05T09:00:00Z"),
    ]
    let entries = try Fixture.entries(commands)
    let staged = Replay.run(entries).settings
    #expect(staged.pendingTimeZone?.value == "Asia/Tokyo")
    #expect(staged.pendingIntensityMode?.value == .highIntensity, "a later staged change replaces one still waiting")

    let millis = try Fixture.millis("2026-03-08T08:00:00Z")
    let state = Replay.run(entries, through: IssueStamp(instantMillis: millis, utcOffsetMinutes: 0, issuedOn: try MemoirStoreFixture.date("2026-03-08")))
    let settings = state.settings
    let date = { (text: String) in try MemoirStoreFixture.date(text) }
    #expect(settings.pendingTimeZone == nil && settings.pendingIntensityMode == nil)
    #expect(settings.timeZone(on: try date("2026-02-28")) == nil)
    #expect(settings.timeZone(on: try date("2026-03-01")) == "Europe/Berlin", "the first zone applies at once")
    #expect(settings.timeZone(on: try date("2026-03-07")) == "Europe/Berlin")
    #expect(settings.timeZone(on: try date("2026-03-08")) == "Asia/Tokyo", "promoted on the day the walk prepared")
    #expect(settings.intensityMode(on: try date("2026-03-07")) == .standard)
    #expect(state.days[try date("2026-03-06")]?.intensityMode == .standard, "the days the absence left close under the old mode")
    #expect(settings.intensityMode(on: try date("2026-03-08")) == .highIntensity)
    #expect(settings.returnerThresholdDays(on: try date("2026-03-05")) == 3)
    #expect(settings.returnerThresholdDays(on: try date("2026-03-04")) == nil)
  }

  @Test func shouldJudgeTheOccurrenceUnderTheModeOfItsOwnDay() throws {
    let commands = [
      try Fixture.command(1, Fixture.create(schedule: try Fixture.routine()), at: "2026-03-01T06:00:00Z"),
      try Fixture.command(2, .accountSetIntensityMode(IntensityModeChange(mode: .lowIntensity)), at: "2026-03-09T20:00:00Z"),
      try Fixture.command(3, .questSkip(QuestBreak(occurrence: try Fixture.occurrence("2026-03-09"))), at: "2026-03-09T21:00:00Z"),
      try Fixture.command(4, .questSkip(QuestBreak(occurrence: try Fixture.occurrence("2026-03-08"))), at: "2026-03-10T08:00:00Z"),
      try Fixture.command(5, .questSkip(QuestBreak(occurrence: try Fixture.occurrence("2026-03-10"))), at: "2026-03-10T08:30:00Z"),
    ]
    let state = Replay.run(try Fixture.entries(commands))
    #expect(state.logs[try Fixture.occurrence("2026-03-09")]?.intensityModeAtLog == .standard)
    #expect(state.logs[try Fixture.occurrence("2026-03-08")]?.intensityModeAtLog == .standard)
    #expect(state.logs[try Fixture.occurrence("2026-03-10")]?.intensityModeAtLog == .lowIntensity)
  }

  @Test func shouldConfirmASubscriptionCycleOnce() throws {
    let subscription = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000d1")
    let cycle = CycleConfirmation(subscription: subscription, billingDate: try MemoirStoreFixture.date("2026-03-05"))
    let commands = [
      try Fixture.command(1, .subscriptionConfirmCycle(cycle), at: "2026-03-05T08:00:00Z"),
      try Fixture.command(2, .subscriptionCreate(RecordReference(id: subscription)), at: "2026-03-05T08:01:00Z"),
      try Fixture.command(3, .subscriptionConfirmCycle(cycle), at: "2026-03-05T08:02:00Z"),
      try Fixture.command(4, .subscriptionConfirmCycle(cycle), at: "2026-03-05T08:03:00Z"),
      try Fixture.command(5, .subscriptionDelete(RecordReference(id: subscription)), at: "2026-03-05T08:04:00Z"),
      try Fixture.command(6, .subscriptionUpdate(RecordReference(id: subscription)), at: "2026-03-05T08:05:00Z"),
    ]
    let state = Fixture.fold(try Fixture.entries(commands))
    #expect(state.outcomes[commands[0].id] == .refused(.subscriptionNotFound))
    #expect(state.outcomes[commands[3].id] == .applied)
    #expect(state.outcomes[commands[5].id] == .refused(.subscriptionNotFound))
    #expect(state.hero.coins == Ruleset.v1.subscriptionConfirmationCoins)
    #expect(state.progression.counters.subscriptionsConfirmed == 1)
    #expect(state.progression.achievements[.firstSubscriptionConfirmed] == cycle.billingDate)
  }

  @Test func shouldCountAScannedReceipt() throws {
    let state = Fixture.fold(try Fixture.entries([try Fixture.command(1, .receiptScan(ReceiptScan()), at: "2026-03-05T08:00:00Z")]))
    #expect(state.progression.counters.receiptsScanned == 1)
    #expect(state.progression.achievements[.firstReceiptScanned] != nil)
    #expect(state.hero.events.map(\.key) == ["achievement:first_receipt_scanned"])
  }

  @Test func shouldKeepADeletedMetricForLaterCommandsAsTheReferencesSoftDelete() throws {
    let metric = MetricReference(id: MemoirStoreFixture.metric, metricClass: .general)
    let date = try MemoirStoreFixture.date("2026-03-05")
    let commands = [
      try Fixture.command(1, .metricUpdate(metric), at: "2026-03-05T08:00:00Z"),
      try Fixture.command(2, .metricCreate(metric), at: "2026-03-05T08:01:00Z"),
      try Fixture.command(3, .metricDelete(MetricDeletion(metric: metric)), at: "2026-03-05T08:02:00Z"),
      try Fixture.command(4, .metricUpdate(metric), at: "2026-03-05T08:03:00Z"),
      try Fixture.command(5, .metricRegister(MetricRegistration(metric: metric, date: date)), at: "2026-03-05T08:04:00Z"),
      try Fixture.command(6, .metricDelete(MetricDeletion(metric: metric, detach: true)), at: "2026-03-05T08:05:00Z"),
      try Fixture.command(7, .metricCreate(metric), at: "2026-03-05T08:06:00Z"),
    ]
    let state = Fixture.fold(try Fixture.entries(commands))
    #expect(commands.map { state.outcomes[$0.id] } == [.refused(.metricNotFound), .applied, .applied, .applied, .applied, .applied, .superseded])
    #expect(state.records.metrics[metric.id] == ReplayMetric(metricClass: .general, isActive: false))
    #expect(state.hero == .empty)
  }

  @Test func shouldKnowACycleExpenseSoItsEditsAndDeletionApply() throws {
    let subscription = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000d1")
    let cycle = CycleConfirmation(subscription: subscription, billingDate: try MemoirStoreFixture.date("2026-03-05"))
    let expense = RecordReference(id: SubscriptionCycles.expenseID(for: cycle))
    let commands = [
      try Fixture.command(1, .expenseUpdate(expense), at: "2026-03-05T07:00:00Z"),
      try Fixture.command(2, .subscriptionCreate(RecordReference(id: subscription)), at: "2026-03-05T08:00:00Z"),
      try Fixture.command(3, .subscriptionConfirmCycle(cycle), at: "2026-03-05T08:01:00Z"),
      try Fixture.command(4, .expenseUpdate(expense), at: "2026-03-05T08:02:00Z"),
      try Fixture.command(5, .expenseDelete(expense), at: "2026-03-05T08:03:00Z"),
      try Fixture.command(6, .subscriptionConfirmCycle(cycle), at: "2026-03-05T08:04:00Z"),
      try Fixture.command(7, .expenseDelete(expense), at: "2026-03-05T08:05:00Z"),
    ]
    let state = Fixture.fold(try Fixture.entries(commands))
    #expect(
      commands.map { state.outcomes[$0.id] } == [.refused(.expenseNotFound), .applied, .applied, .applied, .applied, .applied, .refused(.expenseNotFound)],
      "a cycle confirmed again does not write its expense again, as finance never re-inserts it")
  }

  @Test func shouldRefuseACompassionCommandIssuedBeforeTheOpenDayUnlessABackwardZoneChangeExplainsIt() throws {
    let openDay = try MemoirStoreFixture.date("2026-03-11")
    func seeded(_ settings: [MemoirCommand]) throws -> ReplayState {
      var state = Fixture.fold(try Fixture.entries(settings))
      state.settings.promotePending(on: openDay)
      state.openDay = openDay
      state.days[openDay] = ReplayDay(date: openDay, intensityMode: .standard, rulesetVersion: 1)
      state.compassion.recoveries[openDay] = RecoveryQuest(
        id: MemoirStoreFixture.commandID(800), date: openDay, sourceQuest: nil, triggerLogs: [], isReturnerDay: false, state: .pending)
      return state
    }
    let first = try Fixture.command(1, .accountSetTimeZone(try TimeZoneChange(identifier: "Asia/Tokyo")), at: "2026-03-01T08:00:00Z")
    let backward = try Fixture.command(2, .accountSetTimeZone(try TimeZoneChange(identifier: "America/New_York")), at: "2026-03-10T08:00:00Z", offsetMinutes: 540)
    let recovery = try Fixture.command(10, .recoveryComplete(RecoveryCompletion()), at: "2026-03-10T23:00:00Z", offsetMinutes: -240)
    let lock = try Fixture.command(11, .planSetLock(.unlocked), at: "2026-03-10T23:01:00Z", offsetMinutes: -240)
    let stale = try Fixture.command(12, .planSetLock(.unlocked), at: "2026-03-08T23:01:00Z", offsetMinutes: -240)

    var explained = try seeded([first, backward])
    for (wall, command) in [(10, recovery), (11, lock), (12, stale)] { Replay.apply(try Fixture.entry(command, wall: Int64(wall)), to: &explained) }
    #expect(explained.outcomes[recovery.id] == .applied)
    #expect(explained.compassion.recoveries[openDay]?.state == .completed)
    #expect(explained.outcomes[lock.id] == .applied)
    #expect(explained.outcomes[stale.id] == .refused(.notAccountDay(stale.issuedOn)), "a gap longer than any zone change leaves is still late")

    var unexplained = try seeded([first])
    for (wall, command) in [(10, recovery), (11, lock)] { Replay.apply(try Fixture.entry(command, wall: Int64(wall)), to: &unexplained) }
    #expect(unexplained.outcomes[recovery.id] == .refused(.notAccountDay(recovery.issuedOn)))
    #expect(unexplained.outcomes[lock.id] == .refused(.notAccountDay(lock.issuedOn)))
    #expect(unexplained.compassion.recoveries[openDay]?.state == .pending)
  }

  /// Each of these is refused by a different check; none may leave a trace beyond its outcome.
  @Test func shouldLeaveTheStateUntouchedByEveryKindOfRefusal() throws {
    let base = Fixture.fold(try Fixture.entries(Self.createAndComplete()), from: Fixture.state(coins: 10))
    let occurrence = try Fixture.occurrence("2026-03-10")
    let refused: [MemoirCommandBody] = [
      .questComplete(try Fixture.occurrence("2026-03-10", of: Fixture.secondQuest)),
      .questComplete(try Fixture.occurrence("2026-03-20")),
      .questPostpone(QuestBreak(occurrence: try Fixture.occurrence("2026-02-20"))),
      .questAttachReason(try QuestReason(occurrence: try Fixture.occurrence("2026-03-09"), reasonTag: .other, hasNote: false)),
      .questDeleteLog(try Fixture.occurrence("2026-03-09")),
      .questUpdate(QuestUpdate(questId: Fixture.secondQuest, patch: try QuestSchedulePatch(durationMinutes: 15))),
      .cosmeticPurchase(.badgeBronze),
      .cosmeticEquip(.badgeBronze),
      .titleDisplay(TitleDisplay(title: .architect)),
      .planSetLock(try PlanLock(locking: [Fixture.quest])),
      .recoveryComplete(RecoveryCompletion()),
      .mealLogPreset(PresetMealEntry(id: MemoirStoreFixture.commandID(700), presetId: MemoirStoreFixture.commandID(701), date: occurrence.date)),
      .subscriptionConfirmCycle(CycleConfirmation(subscription: MemoirStoreFixture.commandID(702), billingDate: occurrence.date)),
    ]
    for (index, body) in refused.enumerated() {
      let command = try Fixture.command(100 + index, body, at: "2026-03-10T09:00:00Z")
      var state = base
      Replay.apply(try Fixture.entry(command, wall: 100), to: &state)
      guard case .refused = state.outcomes[command.id] else {
        Issue.record("\(body.kind) was not refused: \(String(describing: state.outcomes[command.id]))")
        continue
      }
      if case .cosmeticPurchase = body {
        #expect(state.notices.count == base.notices.count + 1)
        state.notices = base.notices
      }
      state.outcomes[command.id] = nil
      state.commandCount -= 1
      #expect(state == base, "\(body.kind) left a trace")
    }
  }

  @Test func shouldReadTheOpenDayAheadOfTheZoneAsTheAccountsDay() throws {
    var state = ReplayState.initial
    let zoneDay = try MemoirStoreFixture.date("2026-03-10")
    let openDay = try MemoirStoreFixture.date("2026-03-11")
    #expect(state.accountDay(issuedOn: zoneDay) == zoneDay)
    state.openDay = openDay
    #expect(state.accountDay(issuedOn: zoneDay) == openDay)
    let later = try MemoirStoreFixture.date("2026-03-12")
    #expect(state.accountDay(issuedOn: later) == later)
  }

  @Test func shouldRecordWhatMovesTheDayWalk() throws {
    let state = Fixture.fold(try Fixture.entries(Self.createAndComplete()))
    #expect(state.latestIssuedOn == (try MemoirStoreFixture.date("2026-03-10")))
    #expect(state.highestRulesetVersion == 1)
    #expect(state.commandCount == 2)
    #expect(state.scheduledQuests(on: try MemoirStoreFixture.date("2026-03-10")).map(\.id) == [Fixture.quest])
  }
}
