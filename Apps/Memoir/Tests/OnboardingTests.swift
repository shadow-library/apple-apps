import Foundation
import MemoirCore
import ShadowStore
import ShadowSyncRuntime
import Testing

@testable import Memoir

@Suite("OnboardingDraft", TestTimeLimit.quick)
struct OnboardingDraftTests {
  private func draft() -> OnboardingDraft {
    OnboardingDraft(currency: CurrencyCode("EUR")!, timeZone: "UTC")
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

  @Test("should hold each step until its problem is fixed")
  func findsProblems() {
    var draft = draft()
    #expect(OnboardingStep.allCases.compactMap { draft.problem(at: $0) } == [.nameRequired])
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
@Suite("OnboardingModel", TestTimeLimit.standard)
struct OnboardingModelTests {
  private func walk(_ model: OnboardingModel) {
    while model.step != .ready {
      let step = model.step
      model.advance()
      #expect(model.step != step, "stuck at \(step) with \(String(describing: model.problem))")
      if model.step == step { return }
    }
  }

  @Test("should create the settings record, the first time zone and the first quest in one write, stamped in the chosen zone")
  func createsTheVault() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = OnboardingModel(context: world.context, locale: Locale(identifier: "en_US"))
    #expect(model.draft.currency == CurrencyCode("USD"))
    #expect(model.draft.timeZone == TestClock.utc.identifier, "the device's zone")
    model.draft.timeZone = "Europe/Berlin"
    model.draft.currency = CurrencyCode("GBP")!
    model.draft.wakeMinute = 7 * 60
    model.draft.sleepMinute = 23 * 60
    model.setName("Read 10 pages")
    model.draft.strictness = .routine
    model.draft.recurrence = .count
    model.draft.timesPerWeek = 3
    walk(model)

    #expect(await model.finish())

    let gbp = CurrencyCode("GBP")!
    #expect(try await world.record() == AccountSettingsRecord(defaultCurrency: gbp, enabledCurrencies: [gbp], schedule: try #require(ScheduleWindow(start: 7 * 60, end: 23 * 60))))
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
    #expect(model.failure == nil)
  }

  @Test("should start the account on the chosen zone's day across the date line")
  func startsOnTheZonesDay() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = OnboardingModel(context: world.context)
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
  }

  @Test("should hold the last step while sync brings another device's data or waits for its key")
  func waitsForSync() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = OnboardingModel(context: world.context)
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
    let model = OnboardingModel(context: world.context)
    model.advance()
    #expect(model.step == .quest)

    model.advance()
    #expect(model.step == .quest && model.nameTouched)

    model.setName("Walk 20 minutes")
    model.advance()
    model.advance()
    model.draft.strictness = .anchor
    model.advance()
    #expect(model.step == .strictness && model.startTimeTouched)
    #expect(await model.finish() == false, "finish is only offered on the last step")
    #expect(try await world.commands().isEmpty)

    model.back()
    #expect(model.step == .schedule)
  }

  @Test("should write nothing and give way when the vault was set up meanwhile")
  func givesWayToSyncedData() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let model = OnboardingModel(context: world.context)
    model.setName("Read")
    walk(model)
    try await world.createSettings("EUR")

    #expect(await model.finish())

    #expect(try await world.commands().isEmpty)
    #expect(try await world.context.stores.quests().isEmpty)
    #expect(try await world.record()?.defaultCurrency == CurrencyCode("EUR"))
    #expect(model.failure == nil)
  }

  @Test("should say why setup failed after the settings record was written, and roll the whole write back")
  func showsAFailure() async throws {
    let farFuture = Flag()
    let clock = TestClock(day: 0, minute: 720)
    let broken = MemoirClock(now: { farFuture.isSet ? Date(timeIntervalSince1970: 1e12) : clock.now() }, deviceZone: { TestClock.utc })
    let world = try await SettingsWorld(zone: nil, currency: nil, clock: broken)
    defer { world.stop() }
    let model = OnboardingModel(context: world.context)
    model.setName("Read")
    walk(model)
    farFuture.set()

    #expect(await model.finish() == false)

    #expect(model.failure != nil)
    #expect(try await world.record() == nil)
    #expect(try await world.commands().isEmpty)
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

  @Test("should show the app once onboarding finishes")
  func opensAfterOnboarding() async throws {
    let world = try await SettingsWorld(zone: nil, currency: nil)
    defer { world.stop() }
    let gate = try await world.gate()
    let model = OnboardingModel(context: world.context)
    model.setName("Read")
    while model.step != .ready { model.advance() }

    #expect(await model.finish())

    try await until("the app") { gate.state == .done }
  }
}
