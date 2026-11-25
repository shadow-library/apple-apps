import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("SettingsModel", TestTimeLimit.standard)
struct SettingsModelTests {
  private let eur = CurrencyCode("EUR")!
  private let usd = CurrencyCode("USD")!

  @Test("should save a valid wake and sleep window to the settings record without a command")
  func savesTheSchedule() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel()
    let before = try await world.bodies()

    await model.setWake(7 * 60)

    #expect(try await world.record()?.schedule == ScheduleWindow(start: 7 * 60, end: ScheduleWindow.standard.end))
    #expect(try await world.bodies() == before, "the day window is a record field, not a command")
    try await until("the saved window") { model.shownSchedule == ScheduleDraft(wake: 7 * 60, sleep: ScheduleWindow.standard.end) && model.scheduleDraft == nil }
    #expect(model.failure == nil)
  }

  @Test("should keep a pair outside three to fourteen hours of sleep unsaved until the next valid pair saves both")
  func holdsAnInvalidSchedule() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel()

    await model.setSleep(5 * 60)

    #expect(model.scheduleProblem == .tooShort(sleepMinutes: 60))
    #expect(model.shownSchedule == ScheduleDraft(wake: ScheduleWindow.standard.start, sleep: 5 * 60))
    #expect(try await world.record()?.schedule == .standard)

    await model.setWake(13 * 60)

    #expect(model.scheduleProblem == nil)
    #expect(try await world.record()?.schedule == ScheduleWindow(start: 13 * 60, end: 5 * 60))
  }

  @Test("should save only the pair the pickers rest on, not every step on the way")
  func debouncesTheSchedule() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel(scheduleDelay: .milliseconds(400))

    let steps = [6 * 60 + 15, 6 * 60 + 30].map { minute in Task { await model.setWake(minute) } }
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.shownSchedule?.wake == 6 * 60 + 30, "the pickers show the pair at once")
    #expect(try await world.record()?.schedule == .standard, "nothing is saved while the pickers move")
    await model.setWake(6 * 60 + 45)
    for step in steps { await step.value }

    #expect(try await world.record()?.schedule == ScheduleWindow(start: 6 * 60 + 45, end: ScheduleWindow.standard.end))
  }

  @Test("should stage a time zone change for the next day and show it pending while the zone in force stays")
  func stagesTheTimeZone() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel()

    #expect(await model.setTimeZone("Europe/Berlin"))

    #expect(try await world.bodies().last == .accountSetTimeZone(try TimeZoneChange(identifier: "Europe/Berlin")))
    try await until("the pending zone") { model.snapshot.state.value?.pendingZone == "Europe/Berlin" }
    let snapshot = try #require(model.snapshot.state.value)
    #expect(snapshot.zone.inForce == "UTC" && snapshot.chosenZone == "Europe/Berlin")

    let count = try await world.bodies().count
    #expect(await model.setTimeZone("Europe/Berlin"))
    #expect(try await world.bodies().count == count, "choosing the zone already chosen writes nothing")
  }

  @Test("should set the first time zone at once")
  func setsTheFirstTimeZone() async throws {
    let world = try await SettingsWorld(zone: nil)
    defer { world.stop() }
    let model = try await world.settingsModel()
    #expect(model.snapshot.state.value?.zone.inForce == nil)

    await model.setTimeZone("Asia/Tokyo")

    try await until("the zone in force") { model.snapshot.state.value?.zone.inForce == "Asia/Tokyo" }
    #expect(model.snapshot.state.value?.pendingZone == nil)
  }

  @Test("should refuse a zone this device does not know and write nothing")
  func refusesAnUnknownZone() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel()
    let before = try await world.bodies()

    #expect(await model.setTimeZone("Mars/Olympus_Mons") == false)

    #expect(model.failure(for: .timeZone) != nil)
    #expect(try await world.bodies() == before)
  }

  @Test("should stage the intensity for the next day and show the mode in force beside it")
  func stagesTheIntensity() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel()

    await model.setIntensity(.lowIntensity)

    #expect(try await world.bodies().last == .accountSetIntensityMode(IntensityModeChange(mode: .lowIntensity)))
    try await until("the pending intensity") { model.snapshot.state.value?.pendingIntensity == .lowIntensity }
    #expect(model.snapshot.state.value?.intensity == .standard)
    #expect(model.snapshot.state.value?.chosenIntensity == .lowIntensity)
  }

  @Test("should set the week start")
  func setsTheWeekStart() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel()

    await model.setWeekStart(.sunday)

    #expect(try await world.record()?.weekStart == 0)
  }

  @Test("should enable and disable a currency, never the home currency")
  func editsTheCurrencies() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel()

    await model.setCurrency(usd, enabled: true)
    #expect(try await world.record()?.enabledCurrencies == [eur, usd])
    try await until("the enabled currency") { model.account?.enabledCurrencies == [eur, usd] }

    await model.setCurrency(eur, enabled: false)
    #expect(try await world.record()?.enabledCurrencies == [eur, usd])

    await model.setCurrency(usd, enabled: false)
    #expect(try await world.record()?.enabledCurrencies == [eur])
  }

  @Test("should set the home currency once on a vault without settings and never change it after")
  func setsTheHomeCurrencyOnce() async throws {
    let world = try await SettingsWorld(currency: nil)
    defer { world.stop() }
    let model = try await world.settingsModel()
    #expect(model.snapshot.state.value?.account == .unset)

    await model.setHomeCurrency(CurrencyCode("GBP")!)

    #expect(try await world.record() == AccountSettingsRecord(defaultCurrency: CurrencyCode("GBP")!, enabledCurrencies: [CurrencyCode("GBP")!]))
    try await until("the saved currency") { model.account != nil }

    await model.setHomeCurrency(usd)
    #expect(try await world.record()?.defaultCurrency == CurrencyCode("GBP")!)
  }

  @Test("should refuse to show a title not yet earned, and show one that is")
  func displaysTitles() async throws {
    let hero = try await HeroWorld()
    let model = SettingsModel(context: hero.context)
    let task = Task { await model.run() }
    defer { task.cancel() }
    try await until("the settings") { model.snapshot.state.value != nil }

    await model.displayTitle(.returner)
    #expect(model.failure(for: .title)?.headline == String(localized: "That title hasn’t been earned yet.", table: "Writing"))
    #expect(try await hero.commands().contains { if case .titleDisplay = $0 { true } else { false } } == false)

    try await hero.returnAfterABreak()
    try await until("the earned title") { model.snapshot.state.value?.earnedTitles.contains { $0.id == .returner } == true }
    await model.displayTitle(.returner)

    #expect(try await hero.commands().last == .titleDisplay(TitleDisplay(title: .returner)))
    try await until("the displayed title") { model.snapshot.state.value?.displayedTitle == .returner }
  }

  @Test("should say when this device does not know the account's zone")
  func showsAnUnknownZone() async throws {
    let world = try await SettingsWorld()
    defer { world.stop() }
    let model = try await world.settingsModel()
    #expect(model.unknownZone == nil)
    let body = try MemoirCommandBody(type: MemoirCommandKind.accountSetTimeZone.commandType, payload: ["timezone": .string("Mars/Olympus_Mons")], occurrence: nil)
    let command = try MemoirCommand(
      id: UUID.v7(at: TestClock.date(day: 0, minute: 721)), body: body, instantMillis: TestClock.millis(day: 0, minute: 721), utcOffsetMinutes: 0,
      issuedOn: TestClock.day0, rulesetVersion: 1)
    _ = try await world.context.stores.main.write { transaction in try command.append(in: &transaction) }
    world.clock.set(day: 1, minute: 720)
    try await world.opened.refreshDay()

    try await until("the unknown zone") { model.unknownZone?.identifier == "Mars/Olympus_Mons" }
    #expect(model.unknownZone?.fallbackOffsetMinutes == 0)
  }
}
