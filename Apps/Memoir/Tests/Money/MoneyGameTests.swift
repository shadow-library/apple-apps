import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

/// An in-memory euro vault on the test clock in UTC with Home's monthly limit at 1 000 from November 2025, Hero and Money on and Quests off unless asked
/// otherwise, and a closer that has not yet been told to follow it. On day 2 (4 March) February has passed its grace days and may close.
@MainActor
final class MoneyGameWorld {
  nonisolated static let euro = CurrencyCode("EUR")!
  nonisolated static let january = LocalDate(isoString: "2026-01-01")!
  nonisolated static let february = LocalDate(isoString: "2026-02-01")!
  nonisolated static let homeLimit: Int64 = 100_000

  let clock: TestClock
  let opened: MemoirOpenedVault
  let context: MemoirScreenContext
  let closer = BudgetPeriodCloser()
  let suite = "MoneyGameTests-\(UUID().uuidString)"
  private var tasks: [Task<Void, Never>] = []

  init(day: Int = 2, scoredFrom: LocalDate? = february, modules: [MemoirModule: Bool] = [.quests: false]) async throws {
    clock = TestClock(day: day, minute: 720)
    opened = try await MemoirVaultOpener.open(.inMemory, appVersion: "1", clock: clock.memoir(deviceZone: TestClock.utc))
    context = MemoirScreenContext(opened)
    try await context.writer.issue(try TestQuests.zone("UTC"))
    var settings = AccountSettingsRecord(defaultCurrency: Self.euro, enabledCurrencies: [Self.euro], moneyScoredFrom: scoredFrom)
    for (module, enabled) in modules { settings.setModule(module, enabled: enabled) }
    let record = settings
    let home = BudgetRecord(
      id: HomeBudget.id, currency: Self.euro, limitMinor: Self.homeLimit, period: .monthly, createdOn: LocalDate(isoString: "2025-11-01")!)
    try await context.writer.write { _, transaction in
      _ = try record.create(in: &transaction)
      _ = try home.create(in: &transaction)
    }
  }

  var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

  func stop() {
    closer.follow(nil)
    for task in tasks { task.cancel() }
    UserDefaults.standard.removePersistentDomain(forName: suite)
  }

  /// Follows the vault in the foreground and waits for the run that brings.
  func close() async {
    closer.follow(opened)
    await closer.phaseChanged(isActive: true)?.value
  }

  func game() async throws -> MoneyGameModel {
    let model = MoneyGameModel(context: context, acknowledgements: MoneyCloseAcknowledgements(defaults: defaults))
    tasks.append(Task { await model.run() })
    try await TestClock.until("the money game") { model.snapshot != nil }
    return model
  }

  func bodies() async throws -> [MemoirCommandBody] {
    let entries = try await context.stores.main.read { transaction in try MemoirCommand.listing(in: transaction).entries }
    return try entries.sorted { $0.clock < $1.clock }.map { try MemoirCommandBody($0.record) }
  }

  func closes() async throws -> [BudgetPeriodClose] {
    try await bodies().compactMap { body in
      guard case .budgetClosePeriod(let close) = body else { return nil }
      return close
    }
  }

  func settings() async throws -> AccountSettingsRecord? {
    try await context.stores.main.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction).entry?.record }
  }

  /// December's deposit of 300 in savings, before scoring started, and a 400 goal it fills to 75%.
  func saveTowardsAGoal() async throws {
    try await context.writer.write { _, transaction in
      let deposit = SavingsDeposit(
        amountMinor: 30_000, currency: Self.euro, closedOn: LocalDate(isoString: "2026-01-04")!, command: UUID(), spentMinor: 70_000, limitMinor: 100_000,
        medianExpenseMinor: 5_000)
      _ = try SavingsDepositRecord(budget: HomeBudget.id, periodStart: LocalDate(isoString: "2025-12-01")!, deposit: deposit).create(in: &transaction)
      _ = try SavingsGoalRecord(
        id: UUID(), name: "Bike", symbol: "bicycle", targetMinor: 40_000, currency: Self.euro, rank: SavingsGoalRank("a")!, createdOn: Self.january
      ).create(in: &transaction)
    }
  }

  func milestones() async throws -> [GoalMilestoneReached] {
    try await bodies().compactMap { body in
      guard case .goalMilestone(let reached) = body else { return nil }
      return reached
    }
  }

  func deposit(of periodStart: LocalDate) async throws -> SavingsDeposit? {
    try await context.stores.main.read { transaction in
      try SavingsDepositRecord.read(key: .savingsDeposit(budget: HomeBudget.id, periodStart: periodStart), in: transaction).entry?.record.deposit
    }
  }

  func setModules(_ modules: [MemoirModule: Bool]) async throws {
    try await context.writer.write { _, transaction in
      _ = try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { record in
        for (module, enabled) in modules { record.setModule(module, enabled: enabled) }
      }
    }
  }

  func expense(_ amountMinor: Int64, on date: LocalDate) async throws {
    let expense = ExpenseRecord(
      id: UUID.v7(at: clock.now()), amountMinor: amountMinor, currency: Self.euro, occurredOn: date, category: CategoryKey("food")!,
      loggedAtMillis: MemoirClock.millis(clock.now()))
    try await context.writer.write { issuer, transaction in _ = try ExpenseEdits.create(expense, issuer: issuer, in: &transaction) }
  }
}

@MainActor
@Suite("Budget period closer", TestTimeLimit.standard)
struct BudgetPeriodCloserTests {
  @Test("should start scoring, close every ended period oldest first in its own write, then issue the goal milestones savings reached")
  func shouldCloseInOrder() async throws {
    let world = try await MoneyGameWorld(scoredFrom: MoneyGameWorld.january)
    defer { world.stop() }
    try await world.saveTowardsAGoal()

    await world.close()

    let issued = try await world.bodies().compactMap { body -> String? in
      switch body {
      case .budgetClosePeriod(let close): "close \(close.periodStart.isoString) \(close.outcome.rawValue)"
      case .goalMilestone(let reached): "milestone \(reached.milestone.rawValue)"
      default: nil
      }
    }
    #expect(issued == ["close 2026-01-01 unscored", "close 2026-02-01 unscored", "milestone p25", "milestone p50", "milestone p75"])
    await world.closer.request()?.value
    #expect(try await world.closes().count == 2, "a later run finds nothing left to close")
  }

  @Test("should write no close, deposit or milestone once Hero is off as the write reads the modules, and close again once it is on")
  func shouldCheckTheModulesInsideTheWrite() async throws {
    let world = try await MoneyGameWorld(scoredFrom: MoneyGameWorld.january)
    defer { world.stop() }
    try await world.saveTowardsAGoal()
    let periods = try await BudgetCloseReads.closable(in: world.context.stores, today: TestClock.day(2), now: world.clock.now())
    #expect(periods.map(\.period.start) == [MoneyGameWorld.january, MoneyGameWorld.february])
    #expect(try await GoalMilestones.due(in: world.context.stores, today: TestClock.day(2)).count == 3)

    let refused = try await world.context.writer.write { issuer, transaction in
      _ = try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { $0.setModule(.hero, enabled: false) }
      var closes = [BudgetCloseWrite?]()
      for period in periods { closes.append(try BudgetPeriodCloser.close(period, issuer: issuer, in: &transaction)) }
      return (closes, try BudgetPeriodCloser.issueMilestones(issuer: issuer, in: &transaction))
    }

    #expect(refused.0 == [nil, nil] && refused.1 == 0)
    #expect(try await world.closes().isEmpty)
    #expect(try await world.milestones().isEmpty)
    #expect(try await world.deposit(of: MoneyGameWorld.january) == nil)
    #expect(try await world.deposit(of: MoneyGameWorld.february) == nil)

    try await world.setModules([.hero: true])
    let january = try #require(periods.first)
    let closed = try await world.context.writer.write { issuer, transaction in try BudgetPeriodCloser.close(january, issuer: issuer, in: &transaction) }
    guard case .closed? = closed else { throw MoneyGameTestError.notClosed }
    #expect(try await world.deposit(of: MoneyGameWorld.january) != nil)
  }

  @Test("should follow the vault's changes again at the next request after following them failed")
  func shouldFollowAgainAfterAFailure() async throws {
    let world = try await MoneyGameWorld(modules: [.quests: false, .hero: false])
    defer { world.stop() }
    var subscriptions = 0
    let closer = BudgetPeriodCloser { opened in
      subscriptions += 1
      guard subscriptions > 1 else { return AsyncThrowingStream { $0.finish(throwing: StoreError.corruptStore("scripted")) } }
      return BudgetPeriodCloser.triggers(opened)
    }
    defer { closer.follow(nil) }

    closer.follow(world.opened)
    try await TestClock.until("following fails") { subscriptions == 1 && !closer.isFollowingChanges }
    await closer.phaseChanged(isActive: true)?.value
    #expect(subscriptions == 2 && closer.isFollowingChanges)

    try await world.setModules([.hero: true])

    try await TestClock.until("Hero on is followed and February closes") { try await world.closes().count == 1 }
  }

  @Test("should set the scoring day on a vault that never scored money, closing nothing before it")
  func shouldStartScoringFirst() async throws {
    let world = try await MoneyGameWorld(scoredFrom: nil)
    defer { world.stop() }

    await world.close()

    #expect(try await world.settings()?.moneyScoredFrom == TestClock.day(2))
    #expect(try await world.closes().isEmpty)
  }

  @Test("should close nothing while Hero or Money is off, and close once both are on, as when the change arrives from another device")
  func shouldFollowTheModules() async throws {
    let world = try await MoneyGameWorld(modules: [.quests: false, .hero: false])
    defer { world.stop() }

    await world.close()
    #expect(try await world.closes().isEmpty)
    #expect(try await world.settings()?.moneyScoredFrom == MoneyGameWorld.february)

    try await world.setModules([.hero: true])

    try await TestClock.until("February closes") { try await world.closes().count == 1 }
    #expect(try await world.closes().first?.periodStart == MoneyGameWorld.february)
  }

  @Test("should never follow the demo's vault")
  func shouldSkipTheDemo() async throws {
    let world = try await MoneyGameWorld()
    defer { world.stop() }
    var demo = world.opened
    demo.isDemo = true

    world.closer.follow(demo)

    #expect(world.closer.phaseChanged(isActive: true) == nil)
    #expect(world.closer.request() == nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await world.closes().isEmpty)
  }

  @Test("should run only in the foreground")
  func shouldWaitForTheForeground() async throws {
    let world = try await MoneyGameWorld()
    defer { world.stop() }

    world.closer.follow(world.opened)
    try await Task.sleep(for: .milliseconds(300))
    #expect(world.closer.request() == nil)
    #expect(try await world.closes().isEmpty)

    let held = FeaturesTesting.holdWrites(of: world.context.stores, for: 1)
    try await TestClock.until("the writer is held") { held.held() }
    let run = world.closer.phaseChanged(isActive: true)
    try await TestClock.until("the run starts and waits for the store") { world.closer.runs == 1 }
    _ = world.closer.phaseChanged(isActive: false)
    await run?.value
    try await held.task.value
    #expect(try await world.closes().isEmpty, "a run stops before its next write once the app leaves the foreground")

    await world.closer.phaseChanged(isActive: true)?.value
    #expect(try await world.closes().count == 1)
  }

  @Test("should close nothing while replay is halted at a command this build cannot read")
  func shouldWaitForAHalt() async throws {
    let world = try await MoneyGameWorld()
    defer { world.stop() }
    let future = try MemoirCommand(
      id: UUID.v7(at: TestClock.date(day: 2, minute: 700)), body: .recoveryComplete(RecoveryCompletion()), instantMillis: TestClock.millis(day: 2, minute: 700),
      utcOffsetMinutes: 0, issuedOn: TestClock.day(2), rulesetVersion: 3)
    _ = try await world.context.stores.main.write { transaction in try future.append(in: &transaction) }

    await world.close()

    #expect(try await world.closes().isEmpty)
  }

  @Test("should close when the account's day turns to the first day a period may close")
  func shouldCloseOnADayTurn() async throws {
    let world = try await MoneyGameWorld(day: 0)
    defer { world.stop() }
    await world.close()
    #expect(try await world.closes().isEmpty, "February's grace days have not passed")

    world.clock.set(day: 2, minute: 1)
    try await world.opened.refreshDay()

    try await TestClock.until("February closes on the day turn") { try await world.closes().count == 1 }
  }

  @Test("should run one at a time, a request during a run making exactly one more")
  func shouldSerialiseRuns() async throws {
    let world = try await MoneyGameWorld()
    defer { world.stop() }
    _ = world.closer.phaseChanged(isActive: true)
    let held = FeaturesTesting.holdWrites(of: world.context.stores, for: 1)
    try await TestClock.until("the writer is held") { held.held() }
    world.closer.follow(world.opened)
    try await TestClock.until("the first run starts") { world.closer.runs == 1 }

    let first = world.closer.request()
    let second = world.closer.request()
    #expect(first != nil && first == second, "a request during a run joins it")
    await first?.value
    try await held.task.value

    #expect(world.closer.runs == 2)
    #expect(try await world.closes().count == 1)
  }

  @Test("should stop following the vault when it is deleted")
  func shouldStopOnDeletion() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    world.closer.follow(opened)
    _ = world.closer.phaseChanged(isActive: true)

    try await world.deletion().delete()

    #expect(world.vault.opened?.stores.main !== opened.stores.main)
    #expect(world.closer.request() == nil, "the deleted vault is no longer followed")
    await world.runtimes.shutDown()
  }
}

@MainActor
@Suite("Money in the game", TestTimeLimit.standard)
struct MoneyGameModelTests {
  @Test("should offer No spend for today only while nothing covers it, log it once, and refuse it again with the reason")
  func shouldLogNoSpendToday() async throws {
    let world = try await MoneyGameWorld()
    defer { world.stop() }
    let model = try await world.game()
    let today = TestClock.day(2)
    #expect(model.snapshot?.noSpendToday?.date == today)
    #expect(model.snapshot?.hasActivity == false)

    #expect(await model.logNoSpend(on: today) == .logged)

    try await TestClock.until("today is covered") { model.snapshot?.standing.today?.coverage == .noSpend }
    #expect(model.snapshot?.noSpendToday == nil)
    #expect(model.snapshot?.hasActivity == true)
    #expect(MoneyGameCopy.covered(model.snapshot?.standing.today?.coverage) == "Today is logged as a day without spending.")
    #expect(await model.logNoSpend(on: today) == .unavailable(.alreadyCovered(.noSpend)))
    #expect(model.problem == "That day is already logged as no spend.")
    #expect(try await world.bodies().filter { $0 == .moneyNoSpend(NoSpendDay(date: today)) }.count == 1)
  }

  @Test("should offer the earlier days of the window nothing covers, name yesterday, and refuse a day past the window")
  func shouldBackFill() async throws {
    let world = try await MoneyGameWorld()
    defer { world.stop() }
    try await world.expense(1_200, on: TestClock.day(2))
    let model = try await world.game()
    try await TestClock.until("today is covered by the expense") { model.snapshot?.standing.today?.coverage == .expense }
    let snapshot = try #require(model.snapshot)
    #expect(snapshot.noSpendToday == nil)
    #expect(snapshot.noSpendBackFill.map(\.date) == [TestClock.day(1), TestClock.day(0)])
    #expect(MoneyGameCopy.noSpend(on: TestClock.day(1), today: snapshot.today, locale: MoneyFixture.english) == "Log yesterday as no spend")
    #expect(MoneyGameCopy.noSpend(on: TestClock.day(0), today: snapshot.today, locale: MoneyFixture.english) == "Log Mar 2 as no spend")

    #expect(await model.logNoSpend(on: TestClock.day(1)) == .logged)
    try await TestClock.until("yesterday leaves the back-fill") { model.snapshot?.noSpendBackFill.map(\.date) == [TestClock.day(0)] }
    #expect(await model.logNoSpend(on: TestClock.day(-1)) == .unavailable(.loggingWindowClosed))
    #expect(model.problem == "That day is too long ago to log.")
  }

  @Test("should show each new close with its outcome, fine, debuff and deposit once, and remember it was seen on this device")
  func shouldShowNewClosesOnce() async throws {
    let world = try await MoneyGameWorld()
    defer { world.stop() }
    await world.close()
    let model = try await world.game()
    try await TestClock.until("the close shows") { model.newCloses.count == 1 }
    let close = try #require(model.newCloses.first)
    #expect(close.outcome == .unscored && MoneyGameCopy.closeName(close) == "Home")
    let locale = MoneyFixture.english
    #expect(MoneyGameCopy.outcome(close.outcome, locale: locale) == "Too few days logged to judge")
    #expect(MoneyGameCopy.result(close.result, locale: locale) == ["No coins left to fine", "XP −40% until Apr 2"])
    #expect(model.snapshot?.deposits[close.key]?.amountMinor == 0)
    #expect(MoneyGameCopy.deposit(model.snapshot?.deposits[close.key], locale: locale) == nil)

    model.acknowledgeCloses()

    #expect(model.newCloses.isEmpty)
    #expect(MoneyCloseAcknowledgements(defaults: world.defaults).closes == [close.key])
    let again = try await world.game()
    #expect(again.newCloses.isEmpty, "seen on this device stays seen")
  }

  @Test("should keep the seen closes to a bounded list, the latest kept")
  func shouldBoundTheSeenCloses() {
    let suite = "MoneyGameTests-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let acknowledgements = MoneyCloseAcknowledgements(defaults: UserDefaults(suiteName: suite)!)
    let keys = (0..<(MoneyCloseAcknowledgements.limit + 3)).map { MoneyCloseKey(budget: UUID(), periodStart: TestClock.day($0)) }

    acknowledgements.acknowledge(keys)

    #expect(acknowledgements.closes == Set(keys.suffix(MoneyCloseAcknowledgements.limit)))
  }

  @Test("should hide the money streak until any money activity, then show the week, the debuff and Home in danger on the hero cards")
  func shouldDescribeTheHeroCards() async throws {
    let world = try await MoneyGameWorld()
    defer { world.stop() }
    let model = try await world.game()
    let fresh = try #require(model.snapshot)
    #expect(!fresh.hasActivity && fresh.standing.debuff == nil && fresh.homeInDanger == nil)

    await world.close()
    try await world.expense(85_000, on: TestClock.day(2))

    try await TestClock.until("the debuff and Home at risk show") { model.snapshot?.standing.debuff != nil && model.snapshot?.homeInDanger != nil }
    let snapshot = try #require(model.snapshot)
    #expect(snapshot.hasActivity)
    let week = try #require(snapshot.standing.week)
    #expect(TodayMoneyCopy.streak(snapshot.standing.weekStreak, week: week) == "Money streak 0 weeks · 1 of 5 days this week")
    let debuff = try #require(snapshot.standing.debuff)
    #expect(TodayMoneyCopy.debuff(debuff, locale: MoneyFixture.english).hasPrefix("XP −40% until "))
    #expect(MoneyGameCopy.debuff(debuff, locale: MoneyFixture.english) == "XP −40% until Apr 2")
    let home = try #require(snapshot.homeInDanger)
    #expect(TodayMoneyCopy.home(BudgetRowContent(home, locale: MoneyFixture.english).status).hasPrefix("Home: At risk"))
    #expect(HeroMoneyCopy.streak(1) == "1 week in a row")
  }

  @Test("should withhold momentum on Today's hero card without an active quest")
  func shouldGateMomentum() async throws {
    let world = try await TodayTestWorld()
    try await world.start()
    defer { world.stop() }
    #expect(try world.snapshot.hero.momentum == .noActiveQuest)

    try await world.quest("Walk")

    let model = world.model
    try await TestClock.until("momentum is measured") {
      guard case .measured = model.snapshot?.hero.momentum else { return false }
      return true
    }
  }

  @Test("should leave out the links Today and Hero offer to screens the modules hide")
  func shouldHideLinksToHiddenScreens() {
    let questsAndHero = ModuleSelection(
      settings: AccountSettingsRecord(
        defaultCurrency: MoneyGameWorld.euro, enabledCurrencies: [MoneyGameWorld.euro], moduleJournal: false, moduleMeals: false, moduleBody: false))
    let map = MemoirNavigationMap(questsAndHero)
    #expect(!map.shows(.destination(.journal)), "End of day's journal link")
    #expect(map.shows(.destination(.planningBoard)) && map.shows(.destination(.hero)) && map.shows(.destination(.insights)))
    let moneyAndHero = ModuleSelection(
      settings: AccountSettingsRecord(
        defaultCurrency: MoneyGameWorld.euro, enabledCurrencies: [MoneyGameWorld.euro], moduleQuests: false, moduleJournal: false, moduleMeals: false,
        moduleBody: false))
    let hidden = MemoirNavigationMap(moneyAndHero)
    #expect(!hidden.shows(.destination(.today)) && !hidden.shows(.destination(.planningBoard)), "Coming back's choices")
    #expect(hidden.shows(.destination(.hero)) && hidden.shows(.destination(.money)))
  }
}

enum MoneyGameTestError: Error {
  case notClosed
}
