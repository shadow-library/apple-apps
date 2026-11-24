import Foundation
import MemoirCore
import ShadowStore
import ShadowSyncRuntime
import Testing

@testable import Memoir

@Suite("OnboardingDraft", TestTimeLimit.quick)
struct OnboardingDraftTests {
  private func draft(_ preset: OnboardingPreset? = .habits, format: AmountFormat = SettingsWorld.english) -> OnboardingDraft {
    var draft = OnboardingDraft(currency: CurrencyCode("EUR")!, timeZone: "UTC", format: format)
    draft.purpose = preset.map(OnboardingPurpose.preset)
    return draft
  }

  @Test("should schedule every day, the chosen days, or a count spread across the week")
  func schedulesDays() {
    var draft = draft()
    draft.recurrence = .daily
    #expect(draft.scheduledDays.count == 7)
    draft.recurrence = .chosen
    draft.chosenDays = [.tuesday, .saturday]
    #expect(draft.orderedScheduledDays == [.tuesday, .saturday])
    draft.recurrence = .count
    draft.timesPerWeek = 3
    #expect(draft.orderedScheduledDays == [.monday, .wednesday, .friday], "SPREAD_DAYS, onboarding-screen.tsx:75-83")
    draft.timesPerWeek = 2
    #expect(draft.orderedScheduledDays == [.tuesday, .friday])
  }

  @Test("should walk only the steps the chosen modules need")
  func buildsThePath() {
    let start: [OnboardingStep] = [.purpose, .day, .currency]
    let quest: [OnboardingStep] = [.quest, .schedule, .strictness]
    #expect(draft(.spending).path == start + [.budget, .ready])
    #expect(draft(.habits).path == start + quest + [.ready])
    #expect(draft(.both).path == start + quest + [.budget, .ready])
    #expect(draft(.everything).path == start + quest + [.budget, .ready])
    #expect(draft(nil).path == start + [.ready], "nothing chosen yet")
    var custom = draft(nil)
    custom.purpose = .custom([.journal, .meals])
    #expect(custom.path == start + [.ready])
    custom.purpose = .custom([.hero, .money])
    #expect(custom.path == start + [.budget, .ready])
  }

  @Test("should refuse the modules ModuleSelection refuses, with nothing chosen read as empty")
  func refusesModules() {
    var draft = draft(nil)
    #expect(draft.problem(at: .purpose) == .modules(.empty))
    let cases: [(Set<MemoirModule>, OnboardingProblem?)] = [
      ([], .modules(.empty)), ([.quests], .modules(.questsNeedHero)), ([.quests, .money], .modules(.questsNeedHero)),
      ([.hero], .modules(.heroNeedsQuestsOrMoney)), ([.hero, .journal], .modules(.heroNeedsQuestsOrMoney)), ([.hero, .money], nil), ([.body], nil),
    ]
    for (modules, problem) in cases {
      draft.purpose = .custom(modules)
      #expect(draft.problem(at: .purpose) == problem, "\(modules)")
      #expect((draft.settings == nil) == (problem != nil), "no settings for a refused selection")
    }
    for preset in OnboardingPreset.allCases {
      draft.purpose = .preset(preset)
      #expect(draft.problem(at: .purpose) == nil, "\(preset)")
    }
  }

  @Test("should hold each step on the path until its problem is fixed, and ask nothing of steps off it")
  func findsProblems() {
    var draft = draft()
    #expect(draft.path.compactMap { draft.problem(at: $0) } == [.nameRequired])
    draft.sleepMinute = draft.wakeMinute
    #expect(draft.problem(at: .day) == .sleepWindow(.sameTime))
    draft.name = "   "
    #expect(draft.problem(at: .quest) == .nameRequired)
    draft.chosenDays = []
    #expect(draft.problem(at: .schedule) == .noDays)
    draft.recurrence = .daily
    #expect(draft.problem(at: .schedule) == nil)
    draft.strictness = .anchor
    #expect(draft.problem(at: .strictness) == .anchorNeedsTime)
    draft.startMinute = 7 * 60
    #expect(draft.problem(at: .strictness) == nil)

    var spending = self.draft(.spending)
    #expect(spending.isComplete, "the empty quest name is off the path")
    spending.budgetText = "12,5"
    #expect(!spending.isComplete)
    var habits = self.draft()
    habits.name = "Read"
    habits.budgetText = "12,5"
    #expect(habits.isComplete, "the unreadable limit is off the path")
  }

  @Test("should read Home's limit exactly in the home currency, and leave it unset when the field is empty")
  func readsTheLimit() {
    var draft = draft(.spending, format: SettingsWorld.german)
    #expect(draft.budgetLimit == .success(nil) && draft.homeLimitMinor == nil && draft.problem(at: .budget) == nil)
    draft.budgetText = "  1.500,5 "
    #expect(draft.homeLimitMinor == 150_050)
    draft.budgetText = "0"
    #expect(draft.problem(at: .budget) == .budgetZero)
    draft.budgetText = "-5"
    #expect(draft.problem(at: .budget) == .budgetAmount(.negative))
    draft.budgetText = "12.50"
    draft.currency = CurrencyCode("JPY")!
    #expect(draft.problem(at: .budget) == .budgetAmount(.misplacedGrouping), "the German grouping separator")
    draft.budgetText = "12,50"
    #expect(draft.problem(at: .budget) == .budgetAmount(.tooPrecise(allowedPlaces: 0)), "a currency changed after the limit was typed")
    draft.budgetText = "1500"
    #expect(draft.homeLimitMinor == 1_500)
    draft.purpose = .preset(.habits)
    #expect(draft.homeLimitMinor == nil, "no limit is written off a path with Money")
  }

  @Test("should write off only the modules not chosen, and score money only with Hero and Money")
  func writesTheModules() throws {
    let spending = try #require(draft(.spending).settings)
    #expect(spending.modules == [.money])
    #expect(spending.moduleMoney == nil && spending.moduleHero == false && spending.moduleQuests == false && spending.moduleBody == false)
    #expect(spending.moneyScoredFrom == nil && spending.monthlyBudget == nil)
    let everything = try #require(draft(.everything).settings)
    #expect(MemoirModule.allCases.allSatisfy { everything.isEnabled($0) })
    let eur = try #require(CurrencyCode("EUR"))
    #expect(everything == AccountSettingsRecord(defaultCurrency: eur, enabledCurrencies: [eur], schedule: everything.schedule), "nil reads as on")

    #expect(draft(.both).scoresMoney && draft(.everything).scoresMoney)
    #expect(!draft(.habits).scoresMoney && !draft(.spending).scoresMoney)
    var custom = draft(nil)
    custom.purpose = .custom([.hero, .money])
    #expect(custom.scoresMoney)
  }

  @Test("should start on the first scheduled day from today")
  func findsTheFirstDay() {
    var draft = draft()
    #expect(TestClock.day0.weekday == .monday)
    #expect(draft.firstDay(from: TestClock.day0) == TestClock.day0)
    draft.chosenDays = [.friday]
    #expect(draft.firstDay(from: TestClock.day0) == TestClock.day(4))
    draft.chosenDays = []
    #expect(draft.firstDay(from: TestClock.day0) == nil)
  }

  @Test("should draft the first quest as the reference does: ten minutes, timed only as an anchor")
  func draftsTheQuest() throws {
    var draft = draft()
    draft.name = "  Read 10 pages "
    draft.strictness = .optional
    draft.startMinute = 9 * 60
    draft.recurrence = .chosen
    draft.chosenDays = [.monday, .thursday]
    let quest = try draft.quest(startingOn: TestClock.day0)
    #expect(quest.record.name == "Read 10 pages")
    #expect(quest.record.reminderEnabled == false)
    let schedule = quest.creation.schedule
    #expect(schedule.startTimeMinutes == nil, "only an anchor keeps a start time")
    #expect(schedule.durationMinutes == 10 && schedule.statAffinity == .mind && schedule.optionalStreakOptIn)
    #expect(schedule.recurrence.frequency == .weekly([.monday, .thursday]) && schedule.recurrence.startDate == TestClock.day0)

    draft.strictness = .anchor
    draft.recurrence = .daily
    let anchor = try draft.quest(startingOn: TestClock.day0).creation.schedule
    #expect(anchor.startTimeMinutes == 9 * 60 && !anchor.optionalStreakOptIn && anchor.recurrence.frequency == .daily)
  }

  @Test("should agree with ScheduleWindow on every pair of half hours")
  func agreesWithTheScheduleWindow() {
    let minutes = stride(from: 0, to: 1440, by: 30)
    for wake in minutes {
      for sleep in minutes {
        #expect((SleepWindowProblem(wake: wake, sleep: sleep) == nil) == (ScheduleWindow(start: wake, end: sleep) != nil), "\(wake) \(sleep)")
      }
    }
    #expect(SleepWindowProblem(wake: 12 * 60, sleep: 21 * 60) == .tooLong(sleepMinutes: 15 * 60))
    #expect(SleepWindowProblem(wake: 7 * 60, sleep: 0) == nil, "00:00 to 07:00 is seven hours")
  }

  @Test("should show a saved budget so it reads back to the same minor units")
  func formatsTheBudget() throws {
    let eur = CurrencyCode("EUR")!
    let jpy = CurrencyCode("JPY")!
    #expect(SettingsCurrencies.text(minor: 123_456, currency: eur, format: SettingsWorld.german) == "1234,56")
    #expect(SettingsCurrencies.text(minor: 5, currency: eur, format: SettingsWorld.english) == "0.05")
    #expect(SettingsCurrencies.text(minor: 1_500, currency: jpy, format: SettingsWorld.english) == "1500")
    for minor: Int64 in [0, 1, 99, 100, 123_456, 9_999_999_999] {
      let text = SettingsCurrencies.text(minor: minor, currency: eur, format: SettingsWorld.german)
      #expect(try AmountInput.minorUnits(text, currency: eur, format: SettingsWorld.german) == minor)
    }
  }

  @Test("should default the home currency to the locale's when the reference offers it")
  func picksTheStandardCurrency() {
    #expect(SettingsCurrencies.standard(for: Locale(identifier: "en_GB")) == CurrencyCode("GBP"))
    #expect(SettingsCurrencies.standard(for: Locale(identifier: "es_AR")) == CurrencyCode("EUR"), "the peso is not offered")
  }
}

@MainActor
@Suite("OnboardingCopy", TestTimeLimit.quick)
struct OnboardingCopyTests {
  private let bundle = Bundle(for: OnboardingModel.self)

  private func hasCopy(_ text: String) -> Bool {
    !text.isEmpty && bundle.localizedString(forKey: text, value: "missing", table: "Onboarding") != "missing"
  }

  @Test("should have words in Onboarding.xcstrings for every step, module, preset and refusal")
  func coversEveryCase() {
    for step in OnboardingStep.allCases { #expect(hasCopy(OnboardingCopy.title(step)), "\(step)") }
    for module in MemoirModule.allCases { #expect(hasCopy(OnboardingCopy.module(module)) && hasCopy(OnboardingCopy.moduleDescription(module)), "\(module)") }
    for preset in OnboardingPreset.allCases { #expect(hasCopy(OnboardingCopy.preset(preset)) && hasCopy(OnboardingCopy.presetDescription(preset)), "\(preset)") }
    for refusal: ModuleSelectionError in [.empty, .questsNeedHero, .heroNeedsQuestsOrMoney] { #expect(hasCopy(OnboardingCopy.refusal(refusal)), "\(refusal)") }
    #expect(!hasCopy("A module the catalogue never had"), "a missing key reads as missing")
  }

  @Test("should name the chosen modules in the purpose step's order")
  func namesTheModules() {
    #expect(OnboardingCopy.modules([.money, .hero, .quests]) == ["Quests", "Hero", "Money"].formatted(.list(type: .and)))
    #expect(OnboardingCopy.modules([.money]) == "Money")
  }
}

@MainActor
@Suite("OnboardingModel", TestTimeLimit.standard)
struct OnboardingModelTests {
  /// Goes on from the current step to Ready, recording each step it reaches.
  @discardableResult
  private func walk(_ model: OnboardingModel) -> [OnboardingStep] {
    var visited = [model.step]
    while model.step != .ready {
      let step = model.step
      model.advance()
      #expect(model.step != step, "stuck at \(step) with \(String(describing: model.problem))")
      if model.step == step { return visited }
      visited.append(model.step)
    }
    return visited
  }

  private func model(_ world: SettingsWorld, _ preset: OnboardingPreset = .habits) -> OnboardingModel {
    let model = OnboardingModel(context: world.context, locale: Locale(identifier: "en_US"))
    model.choose(preset)
    return model
  }

  @Test("should create the settings, the first time zone, Home with its limit and the first quest in one write, stamped in the chosen zone")
  func createsTheVault() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = OnboardingModel(context: world.context, locale: Locale(identifier: "en_US"))
    #expect(model.draft.currency == CurrencyCode("USD"))
    #expect(model.draft.timeZone == TestClock.utc.identifier, "the device's zone")
    model.choose(.both)
    model.draft.timeZone = "Europe/Berlin"
    model.draft.currency = CurrencyCode("GBP")!
    model.draft.wakeMinute = 7 * 60
    model.draft.sleepMinute = 23 * 60
    model.setName("Read 10 pages")
    model.draft.strictness = .routine
    model.draft.recurrence = .count
    model.draft.timesPerWeek = 3
    model.setBudgetText("1,250.50")
    #expect(walk(model) == [.purpose, .day, .currency, .quest, .schedule, .strictness, .budget, .ready])

    #expect(await model.finish())

    let gbp = CurrencyCode("GBP")!
    var expected = AccountSettingsRecord(defaultCurrency: gbp, enabledCurrencies: [gbp], schedule: try #require(ScheduleWindow(start: 7 * 60, end: 23 * 60)))
    expected.moduleJournal = false
    expected.moduleMeals = false
    expected.moduleBody = false
    expected.moneyScoredFrom = TestClock.day0
    #expect(try await world.record() == expected)
    let commands = try await world.commands()
    let bodies = try commands.map { try MemoirCommandBody($0) }
    #expect(bodies.count == 2)
    #expect(bodies.first == .accountSetTimeZone(try TimeZoneChange(identifier: "Europe/Berlin")))
    guard case .questCreate(let creation) = bodies.last else {
      Issue.record("expected the first quest, got \(bodies)")
      return
    }
    #expect(creation.schedule.strictness == .routine && creation.schedule.recurrence.frequency == .weekly([.monday, .wednesday, .friday]))
    #expect(creation.schedule.recurrence.startDate == TestClock.day0)
    #expect(commands.allSatisfy { $0.utcOffsetMinutes == 60 }, "Berlin is an hour ahead of UTC in March")
    #expect(try await world.context.stores.quests().map(\.name) == ["Read 10 pages"])
    let home = try #require(try await world.home())
    #expect(home.currency == gbp && home.record.createdOn == TestClock.day0 && home.record.period == .monthly)
    #expect(home.limitMinor(on: TestClock.day0) == 125_050, "the first limit holds from this month on")
    #expect(home.pendingLimit(on: TestClock.day0) == nil)
    #expect(model.failure == nil)
  }

  @Test("should set up money alone: its steps only, Money on, no quest, no money scoring, Home without a limit when it is skipped")
  func setsUpMoneyAlone() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = model(world, .spending)
    model.draft.currency = CurrencyCode("EUR")!
    #expect(walk(model) == [.purpose, .day, .currency, .budget, .ready], "an empty limit goes on")

    #expect(await model.finish())

    let record = try #require(try await world.record())
    #expect(record.modules == [.money] && record.moduleMoney == nil)
    #expect(record.moneyScoredFrom == nil && record.monthlyBudget == nil)
    #expect(try await world.bodies() == [.accountSetTimeZone(try TimeZoneChange(identifier: TestClock.utc.identifier))])
    #expect(try await world.context.stores.quests().isEmpty)
    let home = try #require(try await world.home())
    #expect(home.currency == CurrencyCode("EUR") && home.limitMinor(on: TestClock.day0) == nil)
  }

  @Test("should write no quest and no limit for a path without them, and Home all the same")
  func setsUpHabits() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = model(world, .habits)
    model.setName("Walk")
    model.setBudgetText("900")
    #expect(walk(model) == [.purpose, .day, .currency, .quest, .schedule, .strictness, .ready])

    #expect(await model.finish())

    let record = try #require(try await world.record())
    #expect(record.modules == [.hero, .quests] && record.moneyScoredFrom == nil)
    #expect(try await world.home()?.limitMinor(on: TestClock.day0) == nil, "the limit was typed on a path that left Money")
    #expect(try await world.context.stores.quests().map(\.name) == ["Walk"])
  }

  @Test("should score money from the first day with Hero and Money but no quest")
  func scoresMoneyWithoutQuests() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = model(world, .everything)
    model.chooseCustom()
    model.setModule(.quests, enabled: false)
    #expect(model.shownProblem == nil, "Hero keeps Money")
    for module: MemoirModule in [.journal, .meals, .body] { model.setModule(module, enabled: false) }
    model.setName("Ignored")
    model.setBudgetText("300")
    #expect(walk(model) == [.purpose, .day, .currency, .budget, .ready])

    #expect(await model.finish())

    let record = try #require(try await world.record())
    #expect(record.modules == [.hero, .money] && record.moneyScoredFrom == TestClock.day0)
    #expect(try await world.bodies().count == 1)
    #expect(try await world.context.stores.quests().isEmpty)
    #expect(try await world.home()?.limitMinor(on: TestClock.day0) == 30_000)
  }

  @Test("should keep the answers of steps a change of purpose leaves, and write only those on the new path")
  func changesPurpose() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = model(world, .both)
    model.setName("Read")
    model.setBudgetText("500")
    walk(model)
    while model.step != .purpose { model.back() }
    model.choose(.spending)
    #expect(model.draft.name == "Read", "kept, in case Quests is chosen again")
    #expect(walk(model) == [.purpose, .day, .currency, .budget, .ready])

    #expect(await model.finish())

    #expect(try await world.context.stores.quests().isEmpty)
    #expect(try await world.home()?.limitMinor(on: TestClock.day0) == 50_000)
    #expect(try await world.record()?.moneyScoredFrom == nil)
  }

  @Test("should start the account on the chosen zone's day across the date line")
  func startsOnTheZonesDay() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = model(world, .both)
    model.draft.timeZone = "Pacific/Kiritimati"
    model.setName("Read")
    model.draft.recurrence = .daily
    walk(model)
    #expect(model.today == TestClock.day(1), "noon in UTC is two in the morning of the next day at UTC+14")

    #expect(await model.finish())

    let commands = try await world.commands()
    #expect(commands.count == 2)
    #expect(commands.allSatisfy { $0.utcOffsetMinutes == 14 * 60 && $0.issuedOn == TestClock.day(1) })
    guard case .questCreate(let creation)? = try commands.last.map({ try MemoirCommandBody($0) }) else {
      Issue.record("expected the first quest")
      return
    }
    #expect(creation.schedule.recurrence.startDate == TestClock.day(1))
    #expect(try await world.record()?.moneyScoredFrom == TestClock.day(1))
    #expect(try await world.home()?.record.createdOn == TestClock.day(1))
  }

  @Test("should offer the demo and the restore only on the first step")
  func offersTheDemoFirst() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = OnboardingModel(context: world.context)
    #expect(model.step == .purpose && model.offersDemo)
    model.choose(.spending)
    model.advance()
    #expect(model.step == .day && !model.offersDemo)
    walk(model)
    #expect(!model.offersDemo)
    while model.previous != nil { model.back() }
    #expect(model.step == .purpose && model.offersDemo)
  }

  @Test("should hold the first step until ModuleSelection accepts the modules, and show its refusal")
  func holdsThePurpose() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = OnboardingModel(context: world.context)
    #expect(model.shownProblem == nil, "nothing is called wrong before the owner tries")
    model.advance()
    #expect(model.step == .purpose && model.shownProblem == .modules(.empty))

    model.chooseCustom()
    #expect(model.draft.modules == Set(MemoirModule.allCases), "custom starts from every module")
    model.setModule(.hero, enabled: false)
    #expect(model.shownProblem == .modules(.questsNeedHero))
    model.advance()
    #expect(model.step == .purpose)
    model.setModule(.quests, enabled: false)
    #expect(model.shownProblem == nil)
    model.advance()
    #expect(model.step == .day)
    #expect(await model.finish() == false)
    #expect(try await world.record() == nil)
  }

  @Test("should hold the limit until it is an amount above zero, without calling a half-typed one wrong")
  func holdsTheLimit() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = model(world, .spending)
    model.advance()
    model.advance()
    model.advance()
    #expect(model.step == .budget)
    model.setBudgetText("12.5.0")
    #expect(model.shownProblem == nil)
    model.advance()
    #expect(model.step == .budget && model.shownProblem == .budgetAmount(.repeatedDecimalSeparator))
    model.setBudgetText("0")
    #expect(model.shownProblem == nil)
    model.advance()
    #expect(model.shownProblem == .budgetZero)
    model.setBudgetText("12.50")
    model.advance()
    #expect(model.step == .ready)

    model.draft.budgetText = "abc"
    #expect(await model.finish() == false, "a step on the path with a problem holds the write")
    #expect(try await world.record() == nil)
  }

  @Test("should hold the last step while sync brings another device's data or waits for its key")
  func waitsForSync() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = model(world)
    model.setName("Read")
    walk(model)
    let held: [(SyncStatus, OnboardingSyncHold)] = [
      (.syncing, .arriving), (.attentionNeeded(.awaitingKey), .awaitingKey), (.attentionNeeded(.keysMissing(replicas: [])), .awaitingKey),
      (.attentionNeeded(.writingKeyMissing), .awaitingKey),
    ]
    for (status, hold) in held {
      model.syncStatus = status
      #expect(model.syncHold == hold)
      #expect(await model.finish() == false)
    }
    #expect(try await world.commands().isEmpty)
    #expect(try await world.record() == nil)

    model.syncStatus = .attentionNeeded(.quotaFull)
    #expect(model.syncHold == nil, "a problem that brings no other device's data does not hold")
    model.syncStatus = .upToDate
    #expect(await model.finish())
    #expect(try await world.commands().count == 2)
  }

  @Test("should not leave a step with a problem, and mark its field")
  func holdsAStep() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = model(world)
    model.advance()
    model.advance()
    model.advance()
    #expect(model.step == .quest)

    model.advance()
    #expect(model.step == .quest && model.shownProblem == .nameRequired)

    model.setName("Walk 20 minutes")
    model.advance()
    model.advance()
    model.draft.strictness = .anchor
    model.advance()
    #expect(model.step == .strictness && model.shownProblem == .anchorNeedsTime)
    #expect(await model.finish() == false, "finish is only offered on the last step")
    #expect(try await world.commands().isEmpty)

    model.back()
    #expect(model.step == .schedule)
  }

  @Test("should write nothing and give way when the vault was set up meanwhile")
  func givesWayToSyncedData() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = model(world, .both)
    model.setName("Read")
    model.setBudgetText("100")
    walk(model)
    try await world.createSettings("EUR")

    #expect(await model.finish())

    #expect(try await world.commands().isEmpty)
    #expect(try await world.context.stores.quests().isEmpty)
    #expect(try await world.homeRecord() == nil)
    #expect(try await world.record()?.defaultCurrency == CurrencyCode("EUR"))
    #expect(model.failure == nil)
  }

  @Test("should say why setup failed, and write nothing")
  func showsAFailure() async throws {
    let farFuture = Flag()
    let clock = TestClock(day: 0, minute: 720)
    let broken = MemoirClock(now: { farFuture.isSet ? Date(timeIntervalSince1970: 1e12) : clock.now() }, deviceZone: { TestClock.utc })
    let world = try await SettingsWorld(zone: nil, currency: nil, clock: broken)
    defer { world.stop() }
    let model = model(world)
    model.setName("Read")
    walk(model)
    farFuture.set()

    #expect(await model.finish() == false)

    #expect(model.failure != nil)
    #expect(try await world.record() == nil)
    #expect(try await world.commands().isEmpty)
  }

  @Test("should roll the whole write back when Home's limit is refused after the settings and the zone were written")
  func rollsBack() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let eur = try #require(CurrencyCode("EUR"))
    let march = try #require(LocalDate(isoString: "2026-03-01"))
    let home = BudgetRecord(
      id: HomeBudget.id, currency: eur, limitMinor: 10_000, period: .monthly, stagedLimit: StagedAmount(amountMinor: 20_000, from: march),
      createdOn: TestClock.day(-40))
    try await world.context.writer.write { _, transaction in try home.create(in: &transaction) }
    let model = model(world, .both)
    model.draft.currency = eur
    model.setName("Read")
    model.setBudgetText("300")
    walk(model)

    #expect(await model.finish() == false)

    #expect(model.failure != nil, "this month's limit already changed, so a raise is refused")
    #expect(try await world.record() == nil)
    #expect(try await world.commands().isEmpty)
    #expect(try await world.context.stores.quests().isEmpty)
    #expect(try await world.homeRecord() == home)
  }
}

@MainActor
@Suite("OnboardingGate", TestTimeLimit.standard)
struct OnboardingGateTests {
  @Test("should ask to set up an empty vault")
  func asksForAnEmptyVault() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    #expect(try await world.gate().state == .needed)
  }

  @Test("should skip onboarding for a vault with settings")
  func skipsWithSettings() async throws {
    let world = try await SettingsWorld(zone: nil)
    defer { world.stop() }
    #expect(try await world.gate().state == .done)
  }

  @Test("should skip onboarding for a vault with commands but no settings")
  func skipsWithCommands() async throws {
    let world = try await SettingsWorld(currency: nil)
    defer { world.stop() }
    #expect(try await world.gate().state == .done)
  }

  @Test("should give way once another device's data arrives, and stay out of the way")
  func givesWayToArrivingData() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let gate = try await world.gate()
    #expect(gate.state == .needed)

    try await world.context.writer.issue(try TestQuests.zone("UTC"))

    try await until("the app") { gate.state == .done }
    guard gate.state == .done else { return }
    await gate.run(stores: world.context.stores)
    #expect(gate.state == .done, "a vault is never sent back to onboarding")
  }

  @Test("should show the app once onboarding finishes, on a path without a quest too")
  func opensAfterOnboarding() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let gate = try await world.gate()
    let model = OnboardingModel(context: world.context)
    model.choose(.spending)
    while let next = model.next {
      model.advance()
      #expect(model.step == next)
    }

    #expect(await model.finish())

    try await until("the app") { gate.state == .done }
  }
}

extension SettingsWorld {
  func home() async throws -> LiveBudget? {
    try await context.stores.main.read { transaction in try Budgets.live(in: transaction).home }
  }

  func homeRecord() async throws -> BudgetRecord? {
    try await context.stores.main.read { transaction in try BudgetRecord.read(id: HomeBudget.id, in: transaction).entry?.record }
  }
}
