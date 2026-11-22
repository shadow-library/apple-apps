import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

/// The side-quest read models take every reward from the replay projection, so they agree with `Replay.run` where reading the commands would not.
@Suite("Quick-log outcomes", TestTimeLimit.standard)
struct QuickLogOutcomeTests {
  private static let today = MoneyReadsFixture.date("2026-11-21")

  private struct Vault {
    let stores: MemoirStores
    let horizon: IssueStamp

    init(horizon: IssueStamp) throws {
      self.horizon = horizon
      let reconciler = try MemoirReconciler(appVersion: "1", horizon: { horizon })
      stores = try MemoirStores.openInMemory(wallClock: MoneyReadsFixture.wallClock(horizon.issuedOn), projection: reconciler)
    }

    func log(_ commands: [MemoirCommand], sideQuests: [SideQuestRecord]) async throws {
      try await MoneyReadsFixture.seed(stores.main, sideQuests)
      for command in commands { try await ProjectionSupport.append([command], to: stores.main) }
    }

    func replayed() async throws -> ReplayState {
      Replay.run(try await ProjectionSupport.commands(in: stores.main), through: horizon)
    }
  }

  private static func sideQuest(_ number: Int, on date: LocalDate) -> SideQuestRecord {
    SideQuestRecord(id: MoneyReadsFixture.id(number), date: date, name: "Side quest \(number)", loggedAtMillis: MoneyReadsFixture.millis(date, hour: 6) + Int64(number))
  }

  private static func log(_ number: Int, _ sideQuest: UUID, on date: LocalDate, at stamp: IssueStamp, rulesetVersion: Int = 1) throws -> MemoirCommand {
    try ProjectionSupport.command(
      MemoirStoreFixture.commandID(number), .sideQuestLog(SideQuestEntry(id: sideQuest, date: date)), at: stamp, rulesetVersion: rulesetVersion)
  }

  private static func stamp(_ date: LocalDate, hour: Int, offsetMinutes: Int = 0) throws -> IssueStamp {
    let instant = MoneyReadsFixture.millis(date, hour: hour)
    return IssueStamp(
      instantMillis: instant, utcOffsetMinutes: offsetMinutes, issuedOn: try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: offsetMinutes))
  }

  private static func sideQuestXP(_ state: ReplayState, in span: DateSpan) -> Int {
    state.hero.events.filter { $0.type == .sideQuest && span.contains($0.date) }.map(\.xpDelta).reduce(0, +)
  }

  private static func questXP(_ state: ReplayState, in span: DateSpan) -> Int {
    state.logs.all.filter { span.contains($0.occurrence.date) }.map(\.value.xpAwarded).reduce(0, +)
  }

  /// Every side-quest model the Log and Reflect screens read says what replay decided: each log's reward, the day's slots taken and the XP credited.
  @discardableResult
  private static func expectAgreement(_ vault: Vault, today: LocalDate, sourceLocation: SourceLocation = #_sourceLocation) async throws -> SideQuestsOverview {
    let state = try await vault.replayed()
    let overview = try await LogReads.sideQuests(in: vault.stores, today: today)
    let replayed = { (id: UUID) in state.records.quickLogs[id]?.rewarded ?? false }
    #expect(overview.items.map(\.rewarded) == overview.items.map { replayed($0.sideQuest.id) }, "each log's reward", sourceLocation: sourceLocation)
    #expect(overview.rewardedToday == state.records.sideQuestsRewarded[today] ?? 0, "the day's reward slots", sourceLocation: sourceLocation)
    let month = try #require(DateSpan.month(of: today))
    #expect(overview.xpThisMonth == sideQuestXP(state, in: month), "the month's side-quest XP", sourceLocation: sourceLocation)

    let history = try await ReflectReads.history(in: vault.stores, matching: try HistoryQuery.page(1, kinds: [.sideQuest]), bodyClasses: [], today: today)
    let flags = history.records.items.compactMap { record -> Bool? in
      guard case .sideQuest(let sideQuest, let rewarded) = record.item else { return nil }
      return rewarded == replayed(sideQuest.id)
    }
    #expect(flags.count == overview.items.count && flags.allSatisfy { $0 }, "the history's rewards", sourceLocation: sourceLocation)
    let insights = try await ReflectReads.insights(in: vault.stores, period: .thirtyDays, bodyClasses: [], today: today)
    #expect(insights.xp == questXP(state, in: insights.window) + sideQuestXP(state, in: insights.window), "the insight XP", sourceLocation: sourceLocation)
    return overview
  }

  /// A zone moved back from Kiritimati (+14) to UTC holds the account's day on 11 March while the new zone still dates 10 March: a side quest the
  /// clock dates the 10th is behind the account's day and earns nothing, and one dated the 11th is the day's own and earns its slot.
  @Test func shouldRewardSideQuestsByTheAccountsDayAfterABackwardZoneChange() async throws {
    let tenth = MoneyReadsFixture.date("2026-03-10")
    let eleventh = MoneyReadsFixture.date("2026-03-11")
    let vault = try Vault(horizon: try Self.stamp(tenth, hour: 13))
    let kiritimati = try Self.stamp(MoneyReadsFixture.date("2026-03-09"), hour: 20, offsetMinutes: 840)
    let utcAt = { (hour: Int) throws in try Self.stamp(tenth, hour: hour) }
    let behind = Self.sideQuest(1, on: tenth)
    let ahead = Self.sideQuest(2, on: eleventh)
    try await vault.log(
      [
        try ProjectionSupport.command(MemoirStoreFixture.commandID(1), .accountSetTimeZone(try TimeZoneChange(identifier: "Pacific/Kiritimati")), at: kiritimati),
        try ProjectionSupport.command(
          MemoirStoreFixture.commandID(2), .questCreate(QuestCreation(questId: MoneyReadsFixture.id(900), schedule: try ProjectionSupport.routine(starting: tenth))),
          at: kiritimati),
        try ProjectionSupport.command(
          MemoirStoreFixture.commandID(3), .accountSetTimeZone(try TimeZoneChange(identifier: "UTC")),
          at: try Self.stamp(MoneyReadsFixture.date("2026-03-09"), hour: 21, offsetMinutes: 840)),
        try Self.log(4, behind.id, on: tenth, at: try utcAt(11)),
        try Self.log(5, ahead.id, on: eleventh, at: try utcAt(12)),
      ], sideQuests: [behind, ahead])

    let state = try await vault.replayed()
    #expect(state.openDay == eleventh)
    #expect(try utcAt(11).issuedOn == tenth, "the command's own date is the side quest's, which reading the commands took as rewarded")
    let overview = try await Self.expectAgreement(vault, today: eleventh)
    #expect(overview.items.map(\.sideQuest.id) == [ahead.id, behind.id])
    #expect(overview.items.map(\.rewarded) == [true, false])
    #expect(overview.rewardedToday == 1)
    #expect(overview.xpThisMonth == Ruleset.v1.quickLogs[.sideQuest].xp)
  }

  @Test func shouldRewardNoSideQuestLoggedAfterReplayHalted() async throws {
    let vault = try Vault(horizon: MoneyReadsFixture.stamp(Self.today, hour: 13))
    let before = Self.sideQuest(1, on: Self.today)
    let after = Self.sideQuest(2, on: Self.today)
    let futureStamp = MoneyReadsFixture.stamp(Self.today, hour: 8)
    let future = try MemoirCommand(
      id: MemoirStoreFixture.commandID(2), payload: try CommandPayload(["flag": .bool(true)], type: try CommandType("future.feature")),
      instantMillis: futureStamp.instantMillis, utcOffsetMinutes: 0, issuedOn: Self.today, rulesetVersion: 1)
    try await vault.log(
      [
        try Self.log(1, before.id, on: Self.today, at: MoneyReadsFixture.stamp(Self.today, hour: 7)), future,
        try Self.log(3, after.id, on: Self.today, at: MoneyReadsFixture.stamp(Self.today, hour: 9)),
      ], sideQuests: [before, after])

    #expect(try await vault.replayed().halt == .unknownCommandType(command: future.id, type: "future.feature"))
    let overview = try await Self.expectAgreement(vault, today: Self.today)
    #expect(overview.items.map(\.sideQuest.id) == [after.id, before.id])
    #expect(overview.items.map(\.rewarded) == [false, true], "what replay took in before the halt keeps its reward")
    #expect(overview.rewardedToday == 1)
    #expect(overview.unreadable == 0, "the side quests read no command; the hero row says the app needs an update")
  }

  /// Replay gives each command naming a side quest the next slot and keeps the latest outcome for the id, so a fourth log is past the cap.
  @Test func shouldCountEverySlotADuplicatedSideQuestIdTook() async throws {
    let vault = try Vault(horizon: MoneyReadsFixture.stamp(Self.today, hour: 13))
    let twice = Self.sideQuest(1, on: Self.today)
    let second = Self.sideQuest(2, on: Self.today)
    let third = Self.sideQuest(3, on: Self.today)
    try await vault.log(
      [twice.id, twice.id, second.id, third.id].enumerated().map { index, id in
        try Self.log(index + 1, id, on: Self.today, at: MoneyReadsFixture.stamp(Self.today, hour: 7 + index))
      }, sideQuests: [twice, second, third])

    let overview = try await Self.expectAgreement(vault, today: Self.today)
    #expect(overview.items.map(\.sideQuest.id) == [third.id, second.id, twice.id])
    #expect(overview.items.map(\.rewarded) == [false, true, true])
    #expect(overview.rewardedToday == 3)
    #expect(overview.isRewardCapReached)
    #expect(overview.xpThisMonth == 3 * Ruleset.v1.quickLogs[.sideQuest].xp, "replay credited three slots")
  }

  /// A journal entry and a meal on the day each earn the first-of-day reward and the second meal nothing; a backdated side quest earns nothing; the
  /// weight earns its reward on the hero trail but leaves no quick-log row.
  @Test func shouldReadReplaysQuickLogOutcomesByIdAndByDate() async throws {
    let vault = try Vault(horizon: MoneyReadsFixture.stamp(Self.today, hour: 20))
    let yesterday = MoneyReadsFixture.date("2026-11-20")
    let ids = (1...5).map { MoneyReadsFixture.id(40 + $0) }
    let bodies: [MemoirCommandBody] = [
      .journalSave(QuickLogEntry(id: ids[0], date: Self.today)), .mealLog(QuickLogEntry(id: ids[1], date: Self.today)),
      .mealLog(QuickLogEntry(id: ids[2], date: Self.today)), .sideQuestLog(SideQuestEntry(id: ids[3], date: yesterday)),
      .sideQuestLog(SideQuestEntry(id: ids[4], date: Self.today)), .weightSave(WeightEntry(date: Self.today)),
    ]
    try await vault.log(
      try bodies.enumerated().map { index, body in
        try ProjectionSupport.command(MemoirStoreFixture.commandID(index + 1), body, at: MoneyReadsFixture.stamp(Self.today, hour: 7 + index))
      }, sideQuests: [])

    let reward = Ruleset.v1.quickLogs
    let read = try await vault.stores.main.read { transaction in
      (
        journal: try MemoirDerived.quickLog(ids[0], in: transaction), unknown: try MemoirDerived.quickLog(MoneyReadsFixture.id(99), in: transaction),
        meals: try MemoirDerived.quickLogs(.meal, from: Self.today, through: Self.today, in: transaction),
        sideQuests: try MemoirDerived.quickLogs(.sideQuest, from: yesterday, through: Self.today, in: transaction),
        todaysSideQuests: try MemoirDerived.quickLogs(.sideQuest, from: Self.today, through: Self.today, in: transaction),
        weights: try MemoirDerived.quickLogs(.weight, from: .earliest, through: .latest, in: transaction),
        mealDays: try MemoirDerived.quickLogDays(.meal, from: yesterday, through: Self.today, in: transaction),
        sideQuestDays: try MemoirDerived.quickLogDays(.sideQuest, from: .earliest, through: .latest, in: transaction),
        weightDays: try MemoirDerived.quickLogDays(.weight, from: .earliest, through: .latest, in: transaction)
      )
    }
    #expect(read.journal?.source == .journal && read.journal?.date == Self.today && read.journal?.rewarded == true)
    #expect(read.unknown == nil)
    #expect(read.meals.count == 2 && read.meals.count(where: \.rewarded) == 1, "the first meal of the day takes the reward")
    #expect(read.sideQuests.map(\.date) == [yesterday, Self.today])
    #expect(read.sideQuests.map(\.rewarded) == [false, true])
    #expect(read.todaysSideQuests.map(\.id) == [ids[4]])
    #expect(try await vault.replayed().hero.events.contains { $0.type == .weight })
    #expect(read.weights.isEmpty && read.weightDays.isEmpty, "a weight is health class; only the hero trail credits it")
    #expect(read.mealDays == [QuickLogDayRow(date: Self.today, source: .meal, rewarded: 1, reward: RewardAmount(xp: reward[.meal].xp, coins: reward[.meal].coins))])
    #expect(
      read.sideQuestDays == [
        QuickLogDayRow(date: Self.today, source: .sideQuest, rewarded: 1, reward: RewardAmount(xp: reward[.sideQuest].xp, coins: reward[.sideQuest].coins))
      ])
    let stored = try await ProjectionSupport.derived(in: vault.stores.main)
    #expect(stored == (try await ProjectionSupport.expected(in: vault.stores.main, through: vault.horizon)), "the tables equal a full replay")
    #expect(stored.quickLogs.count == 5 && stored.quickLogDays.count == 3)
  }

  @Test func shouldRewardNoSideQuestFromARulesetThisBuildLacksNorAnyAfterIt() async throws {
    let vault = try Vault(horizon: MoneyReadsFixture.stamp(Self.today, hour: 13))
    let newer = Self.sideQuest(1, on: Self.today)
    let later = Self.sideQuest(2, on: Self.today)
    try await vault.log(
      [
        try Self.log(1, newer.id, on: Self.today, at: MoneyReadsFixture.stamp(Self.today, hour: 7), rulesetVersion: 2),
        try Self.log(2, later.id, on: Self.today, at: MoneyReadsFixture.stamp(Self.today, hour: 8)),
      ], sideQuests: [newer, later])

    #expect(try await vault.replayed().halt == .rulesetUnavailable(command: MemoirStoreFixture.commandID(1), version: 2))
    let overview = try await Self.expectAgreement(vault, today: Self.today)
    #expect(overview.items.map(\.rewarded) == [false, false])
    #expect(overview.rewardedToday == 0)
    #expect(overview.xpThisMonth == 0)
  }
}
