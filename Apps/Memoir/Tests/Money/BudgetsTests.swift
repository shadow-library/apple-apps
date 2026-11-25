import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

/// Budgets written straight through `BudgetEdits` and read back as the screens read them, on `TestClock.day0` (2 March 2026, day 2 of 31).
@MainActor
enum BudgetFixture {
  static let english = MoneyFixture.english

  @discardableResult
  static func create(_ context: MemoirScreenContext, _ draft: BudgetDraft) async throws -> UUID {
    let id = UUID.v7(at: context.clock.now())
    try await context.writer.write { _, transaction in _ = try BudgetEdits.create(draft, id: id, today: TestClock.day0, in: &transaction) }
    return id
  }

  static func homeLimit(_ context: MemoirScreenContext, _ minor: Int64) async throws {
    try await context.writer.write { _, transaction in _ = try BudgetEdits.update(HomeBudget.id, today: TestClock.day0, in: &transaction) { $0.limitMinor = minor } }
  }

  static func trip(_ name: String, from: Int, through: Int, currency: CurrencyCode = MoneyFixture.euro, limit: Int64 = 50_000) -> BudgetDraft {
    BudgetDraft(name: name, currency: currency, limitMinor: limit, period: .trip(from: TestClock.day(from), through: TestClock.day(through)))
  }

  static func standings(_ context: MemoirScreenContext) async throws -> BudgetStandings {
    try #require(try await MoneyReads.budgetStandings(in: context.stores, today: TestClock.day0))
  }

  static func row(_ context: MemoirScreenContext, _ id: UUID = HomeBudget.id) async throws -> BudgetRowContent {
    BudgetRowContent(try #require(try await standings(context).standing(of: id)), locale: english)
  }

  static func formOptions(_ context: MemoirScreenContext) async throws -> BudgetFormOptions {
    try #require(try await BudgetFormOptions.load(context))
  }

  static func form(_ context: MemoirScreenContext, editing id: UUID? = nil) async throws -> BudgetForm {
    let options = try await formOptions(context)
    guard let id else { return BudgetForm(options: options, context: context, locale: english) }
    return BudgetForm(editing: try #require(options.standings.standing(of: id)?.budget), options: options, context: context, locale: english)
  }

  static func budget(_ context: MemoirScreenContext, _ id: UUID) async throws -> BudgetRecord? {
    try await context.stores.main.read { transaction in try BudgetRecord.read(id: id, in: transaction).entry?.record }
  }

  static func money(_ minor: Int64, _ currency: CurrencyCode = MoneyFixture.euro) -> String {
    MoneyText.formatted(minor, currency, locale: english)
  }
}

@MainActor
@Suite("Budgets rail", TestTimeLimit.standard)
struct BudgetsRailTests {
  @Test("should stand Home in before it is written, named by the app, without a limit")
  func standsHomeIn() async throws {
    let context = try await MoneyFixture.context()
    #expect(try await BudgetFixture.budget(context, HomeBudget.id) == nil)
    let row = try await BudgetFixture.row(context)
    #expect(row.title == BudgetCopy.home)
    #expect(row.status == String(localized: "No limit set", table: "Money"))
    #expect(row.tone == .neutral && row.progress == nil)
    #expect(BudgetSummary(try await BudgetFixture.standings(context)).value == String(localized: "No limits set", table: "Money"))
  }

  @Test(
    "should say each pace aloud with its symbol: on track, mostly spent, projected over and over",
    arguments: [
      (Int64(1_000), BudgetTone.success, "On track"), (10_000, .warning, "At risk: on pace to go over"), (85_000, .warning, "At risk: mostly spent"),
      (120_000, .danger, "Over by €200.00"),
    ])
  func readsEachPace(spent: Int64, tone: BudgetTone, status: String) async throws {
    let context = try await MoneyFixture.context()
    try await BudgetFixture.homeLimit(context, 100_000)
    try await MoneyFixture.expense(context, spent)

    let row = try await BudgetFixture.row(context)
    #expect(row.status == status)
    #expect(row.tone == tone)
    #expect(tone.symbol != nil)
    #expect(row.amount == "\(BudgetFixture.money(spent)) of €1,000.00")
    #expect(row.accessibilityLabel.contains(status), "VoiceOver reads the pace")
    let safe = row.details.contains { $0.hasSuffix("a day to stay within") }
    #expect(safe == (tone != .danger), "nothing is safe to spend once over")
    #expect(row.details.contains { $0.hasPrefix("On pace for") } == (status == "At risk: on pace to go over"))
  }

  @Test("should show an upcoming trip's start and its daily allowance, a pending limit and expenses waiting for a rate")
  func readsATripAndPendingParts() async throws {
    let context = try await MoneyFixture.context(budgetMinor: 100_000)
    try await BudgetFixture.homeLimit(context, 150_000)
    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Lisbon", from: 5, through: 9))
    try await MoneyFixture.expense(context, 10_000, MoneyFixture.krone)

    let home = try await BudgetFixture.row(context)
    #expect(home.details.contains("Limit €1,500.00 from Apr 1, 2026"))
    #expect(home.details.contains(String(localized: "\(1) rate pending", table: "Money")))
    let lisbon = try await BudgetFixture.row(context, trip)
    #expect(lisbon.title == "Lisbon")
    #expect(lisbon.details.first == "Starts in 5 days")
    #expect(lisbon.details.contains("€100.00 a day once it starts"))
  }

  @Test("should keep a trip that ended before this month off the rail but on the budgets screen")
  func hidesOldTrips() async throws {
    let context = try await MoneyFixture.context()
    let old = try await BudgetFixture.create(context, BudgetFixture.trip("Weekend", from: -3, through: -2))
    let current = try await BudgetFixture.create(context, BudgetFixture.trip("Now", from: -1, through: 2))
    let standings = try await BudgetFixture.standings(context)
    #expect(standings.budgets.map(\.id).first == HomeBudget.id)
    #expect(Set(standings.budgets.map(\.id)) == [HomeBudget.id, old, current])
    #expect(standings.shownOnRail.map(\.id) == [HomeBudget.id, current])
    #expect(BudgetRowContent(try #require(standings.standing(of: old)), locale: BudgetFixture.english).details.first == "Ended Feb 28, 2026")
  }

  @Test("should add the budgets up in the home currency, approximate once anything converts, and note limits still waiting for a rate")
  func addsUp() async throws {
    let context = try await MoneyFixture.context()
    try await BudgetFixture.homeLimit(context, 100_000)
    let kroner = try await BudgetFixture.create(context, BudgetDraft(name: "Kroner", currency: MoneyFixture.krone, limitMinor: 200_000, period: .monthly))
    try await MoneyFixture.expense(context, 10_000)

    var standings = try await BudgetFixture.standings(context)
    #expect(standings.offersConsolidated)
    var content = ConsolidatedContent(standings.consolidated, locale: BudgetFixture.english)
    #expect(content.title == "All budgets in EUR")
    #expect(content.notes.contains("1 limit waits for an exchange rate and is left out."))

    let rate = FxRateRecord(base: MoneyFixture.krone, quote: MoneyFixture.euro, date: TestClock.day0, rate: try #require(DecimalText("0.1")))
    try await context.writer.write { _, transaction in _ = try rate.create(in: &transaction) }
    standings = try await BudgetFixture.standings(context)
    content = ConsolidatedContent(standings.consolidated, locale: BudgetFixture.english)
    #expect(standings.consolidated.budgets.contains(kroner))
    #expect(content.amount == "≈ €100.00 of €1,200.00")
    #expect(content.left == "≈ €1,100.00 left")
    #expect(content.notes.first?.hasPrefix("Approximate") == true)
  }

  @Test("should offer the consolidated toggle only with more than one budget under way, off until turned on")
  func togglesConsolidated() async throws {
    let context = try await MoneyFixture.context()
    let model = MoneyModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }
    let overview = try #require(try await MoneyFixture.loaded(model.overview, "the overview") { $0 != nil })
    #expect(overview.budgets.offersConsolidated == false)
    #expect(!model.showsConsolidated)

    try await BudgetFixture.create(context, BudgetFixture.trip("Now", from: 0, through: 2))
    let both = try await MoneyFixture.loaded(model.overview, "both budgets") { $0?.budgets.budgets.count == 2 }
    #expect(both?.budgets.offersConsolidated == true)
  }

  @Test("should count the budgets under way that are on track, at risk and over")
  func summarises() async throws {
    let context = try await MoneyFixture.context()
    try await BudgetFixture.homeLimit(context, 100_000)
    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Now", from: -1, through: 2, limit: 1_000))
    try await MoneyFixture.expense(context, 5_000)
    try await BudgetFixture.create(context, BudgetFixture.trip("Later", from: 10, through: 12))

    let standings = try await BudgetFixture.standings(context)
    #expect(standings.standing(of: trip)?.pace == .over(byMinor: 4_000))
    let summary = BudgetSummary(standings)
    #expect(summary.value == "1 of 2 on track", "the trip not yet started is not measured")
    #expect(summary.caption == "1 over")
  }
}

@MainActor
@Suite("Budgets screen and form", TestTimeLimit.standard)
struct BudgetFormTests {
  @Test("should follow the standings and delete a budget but never Home")
  func followsAndDeletes() async throws {
    let context = try await MoneyFixture.context()
    let model = BudgetsModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }
    _ = try await MoneyFixture.loaded(model.standings, "Home") { $0?.budgets.count == 1 }
    #expect(model.homeCurrencyDiffers == nil)

    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Lisbon", from: 1, through: 4))
    _ = try await MoneyFixture.loaded(model.standings, "the trip") { $0?.budgets.count == 2 }

    #expect(await model.delete(HomeBudget.id) == false)
    #expect(await model.delete(trip))
    _ = try await MoneyFixture.loaded(model.standings, "the trip gone") { $0?.budgets.count == 1 }
    #expect(await model.delete(trip) == false)
    #expect(model.failure?.headline == WritingErrors.presented(FinanceError.budgetAbsent(trip))?.headline)
  }

  @Test("should name Home's currency when it differs from the account's")
  func notesAHomeCurrencyThatDiffers() async throws {
    let context = try await MoneyFixture.context(home: MoneyFixture.krone, enabled: [MoneyFixture.krone])
    let home = BudgetRecord(id: HomeBudget.id, currency: MoneyFixture.euro, period: .monthly, createdOn: TestClock.day0)
    try await context.writer.write { _, transaction in _ = try home.create(in: &transaction) }
    let model = BudgetsModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }
    _ = try await MoneyFixture.loaded(model.standings, "the standings") { $0 != nil }
    #expect(model.homeCurrencyDiffers == MoneyFixture.euro)
    #expect(try await BudgetFixture.row(context).kind.hasSuffix("EUR"))
  }

  @Test("should create a trip, refusing a blank name, reversed dates and a start further back than the backdating allows")
  func createsATrip() async throws {
    let context = try await MoneyFixture.context()
    let form = try await BudgetFixture.form(context)
    #expect(form.kind == .trip)
    #expect(!form.canSave, "nothing typed")
    form.name = "  "
    form.limitText = "500"
    #expect(form.nameIssue != nil && !form.canSave)
    form.name = " Lisbon "
    form.through = TestClock.day(-1)
    #expect(form.datesIssue == String(localized: "A trip ends on or after the day it starts.", table: "Money"))
    let earliest = try #require(TestClock.day0.adding(days: -BudgetEdits.tripBackdatingDays))
    #expect(form.earliestStart == earliest)
    form.from = try #require(earliest.adding(days: -1))
    form.through = TestClock.day(4)
    #expect(form.datesIssue == "A trip can start on \(MoneyDates.text(earliest, locale: BudgetFixture.english)) at the earliest.")
    #expect(!form.canSave)
    form.from = earliest
    #expect(form.canSave)

    let id = try #require(await form.save())
    let record = try #require(try await BudgetFixture.budget(context, id))
    #expect(record.name == "Lisbon")
    #expect(record.limitMinor == 50_000)
    #expect(record.period == .trip(from: earliest, through: TestClock.day(4)))
    #expect(try await BudgetFixture.budget(context, HomeBudget.id) != nil, "creating a budget writes Home")
    #expect(try await MoneyFixture.bodies(context).isEmpty, "budgets are settings: no command")
  }

  @Test("should show the core's refusal when a trip overlaps another")
  func refusesAnOverlap() async throws {
    let context = try await MoneyFixture.context()
    try await BudgetFixture.create(context, BudgetFixture.trip("Lisbon", from: 1, through: 4))
    let form = try await BudgetFixture.form(context)
    form.name = "Porto"
    form.limitText = "100"
    form.from = TestClock.day(3)
    form.through = TestClock.day(6)
    #expect(await form.save() == nil)
    #expect(form.failure?.headline == String(localized: "Trips can’t share a day. Change the dates so they don’t overlap.", table: "Writing"))
  }

  @Test("should offer a monthly budget only in an enabled currency without one, and say when none is left")
  func offersMonthlyCurrencies() async throws {
    let context = try await MoneyFixture.context(enabled: [MoneyFixture.euro, MoneyFixture.krone, MoneyFixture.yen])
    let form = try await BudgetFixture.form(context)
    #expect(form.currencies == [MoneyFixture.euro, MoneyFixture.krone, MoneyFixture.yen])
    form.kind = .monthly
    #expect(form.currencies == [MoneyFixture.krone, MoneyFixture.yen], "Home holds the euro")
    #expect(form.currency == MoneyFixture.krone)
    form.name = "Kroner"
    form.limitText = "2000"
    let id = try #require(await form.save())
    #expect(try await BudgetFixture.budget(context, id)?.period == .monthly)

    let next = try await BudgetFixture.form(context)
    next.kind = .monthly
    #expect(next.currencies == [MoneyFixture.yen])

    let homeOnly = try await MoneyFixture.context(enabled: [MoneyFixture.euro])
    let lone = try await BudgetFixture.form(homeOnly)
    lone.kind = .monthly
    lone.name = "Nothing"
    lone.limitText = "10"
    #expect(lone.isMonthlyUnavailable && !lone.canSave)
    lone.kind = .trip
    #expect(!lone.isMonthlyUnavailable && lone.currency == MoneyFixture.euro)
  }

  @Test("should give Home its first limit before Home is written, after which a raise waits for next month's own change")
  func setsHomesFirstLimit() async throws {
    let context = try await MoneyFixture.context()
    let first = try await BudgetFixture.form(context, editing: HomeBudget.id)
    #expect(first.isHome && !first.canChangeKindAndCurrency)
    first.limitText = "1000"
    #expect(first.limitChange == .applies(dropping: nil))
    #expect(try #require(await first.save()) == HomeBudget.id)
    #expect(try await BudgetFixture.standings(context).homeBudget?.limitMinor == 100_000)
    #expect(try await BudgetFixture.budget(context, HomeBudget.id)?.name == nil, "Home keeps no name")

    let raise = try await BudgetFixture.form(context, editing: HomeBudget.id)
    raise.limitText = "1500"
    #expect(raise.refusal == .limitChangedThisMonth)
    #expect(raise.limitNote == String(localized: "This month’s limit has already changed. Raise it again next month.", table: "Money"))
    #expect(!raise.canSave)
  }

  @Test("should stage a raise of Home past the month's opening limit for next month, and drop it when set back")
  func stagesHomeRaises() async throws {
    let context = try await MoneyFixture.context(budgetMinor: 100_000)
    let raise = try await BudgetFixture.form(context, editing: HomeBudget.id)
    #expect(raise.limitText == "1000.00", "Home's limit falls back to the account's monthly budget")
    raise.limitText = "1500"
    let april = try #require(LocalDate(year: 2026, month: 4, day: 1))
    #expect(raise.limitChange == .staged(StagedAmount(amountMinor: 150_000, from: april), keeping: 100_000))
    #expect(raise.limitNote == "A raise waits for next month: the new limit starts on Apr 1, 2026, and this month keeps €1,000.00.")
    #expect(await raise.save() == HomeBudget.id)
    let standing = try #require(try await BudgetFixture.standings(context).homeBudget)
    #expect(standing.limitMinor == 100_000 && standing.pendingLimit == StagedAmount(amountMinor: 150_000, from: april))

    let back = try await BudgetFixture.form(context, editing: HomeBudget.id)
    #expect(back.limitText == "1500.00", "the form shows the latest limit")
    back.limitText = "1000"
    #expect(back.limitChange == .applies(dropping: StagedAmount(amountMinor: 150_000, from: april)))
    #expect(back.limitNote?.contains("is dropped") == true)
  }

  @Test("should refuse a second raise in a month past the opening limit before saving, with how far it can go")
  func refusesASecondRaise() async throws {
    let context = try await MoneyFixture.context()
    let kroner = try await BudgetFixture.create(context, BudgetDraft(name: "Kroner", currency: MoneyFixture.krone, limitMinor: 100_000, period: .monthly))
    let lower = try await BudgetFixture.form(context, editing: kroner)
    lower.limitText = "800"
    #expect(lower.limitChange == .applies(dropping: nil))
    #expect(await lower.save() == kroner)

    let raise = try await BudgetFixture.form(context, editing: kroner)
    raise.limitText = "900"
    #expect(raise.limitChange == .applies(dropping: nil), "back up within the opening limit")
    raise.limitText = "1200"
    #expect(raise.refusal == .limitChangedThisMonth)
    #expect(raise.limitNote?.contains("1,000.00") == true)
    #expect(!raise.canSave)
  }

  @Test("should keep a started trip's first day and refuse raising its limit, while lowering it is allowed")
  func locksAStartedTrip() async throws {
    let context = try await MoneyFixture.context()
    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Now", from: 0, through: 4))
    let form = try await BudgetFixture.form(context, editing: trip)
    #expect(form.isStartFixed && form.earliestStart == nil)
    form.limitText = "600"
    #expect(form.refusal == .tripLimitLocked && !form.canSave)
    form.limitText = "400"
    #expect(form.limitChange == .applies(dropping: nil))
    form.name = "Now and then"
    #expect(await form.save() == trip)
    #expect(try await BudgetFixture.budget(context, trip)?.limitMinor == 40_000)
    #expect(try await BudgetFixture.budget(context, trip)?.name == "Now and then")
  }

  @Test("should stage a first or lower one-off threshold for next month and clear it at once")
  func stagesTheThreshold() async throws {
    let context = try await MoneyFixture.context()
    try await BudgetFixture.homeLimit(context, 100_000)
    let form = try await BudgetFixture.form(context, editing: HomeBudget.id)
    #expect(form.currentThreshold == "€100.00", "a tenth of the limit while calibrating")
    form.oneOffText = "300"
    let april = try #require(LocalDate(year: 2026, month: 4, day: 1))
    #expect(form.thresholdChange == .staged(StagedAmount(amountMinor: 30_000, from: april), keeping: nil))
    #expect(form.thresholdNote != nil)
    #expect(await form.save() == HomeBudget.id)
    #expect(try await BudgetFixture.budget(context, HomeBudget.id)?.stagedOneOff == StagedAmount(amountMinor: 30_000, from: april))

    let clear = try await BudgetFixture.form(context, editing: HomeBudget.id)
    #expect(clear.oneOffText == "300.00")
    clear.oneOffText = ""
    #expect(clear.thresholdChange == .applies(dropping: StagedAmount(amountMinor: 30_000, from: april)))
    form.oneOffText = "abc"
    #expect(form.oneOffIssue != nil && !form.canSave)
  }

  @Test("should save only the fields the owner moved, keeping a change written elsewhere while the form was open")
  func keepsConcurrentChanges() async throws {
    let context = try await MoneyFixture.context()
    let kroner = try await BudgetFixture.create(context, BudgetDraft(name: "Kroner", currency: MoneyFixture.krone, limitMinor: 100_000, period: .monthly))
    let form = try await BudgetFixture.form(context, editing: kroner)
    try await context.writer.write { _, transaction in
      _ = try BudgetEdits.update(kroner, today: TestClock.day0, in: &transaction) {
        $0.limitMinor = 80_000
        $0.oneOffFromMinor = 20_000
      }
    }
    form.name = "Norway"
    #expect(await form.save() == kroner)
    let record = try #require(try await BudgetFixture.budget(context, kroner))
    #expect(record.name == "Norway")
    let budget = try #require(try await BudgetFixture.standings(context).standing(of: kroner)?.budget)
    #expect(budget.limitMinor(on: TestClock.day0) == 80_000)
    #expect(BudgetDraft(budget, on: TestClock.day0).oneOffFromMinor == 20_000)
  }

  @Test("should delete a budget from its form, and never offer Home's")
  func deletesFromTheForm() async throws {
    let context = try await MoneyFixture.context()
    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Lisbon", from: 1, through: 4))
    let home = try await BudgetFixture.form(context, editing: HomeBudget.id)
    #expect(await home.delete() == false)
    let form = try await BudgetFixture.form(context, editing: trip)
    #expect(await form.delete())
    let entry = try await context.stores.main.read { transaction in try BudgetRecord.read(id: trip, in: transaction).entry }
    #expect(entry?.isRemoved == true)
  }
}

@MainActor
@Suite("Budget chip", TestTimeLimit.standard)
struct BudgetChipTests {
  @Test("should prefill the chip by the assignment rule and say why: trip, currency, Home converted, Home")
  func prefillsByTheRule() async throws {
    let context = try await MoneyFixture.context(enabled: [MoneyFixture.euro, MoneyFixture.krone, MoneyFixture.yen])
    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Lisbon", from: 2, through: 4))
    let kroner = try await BudgetFixture.create(context, BudgetDraft(name: "Kroner", currency: MoneyFixture.krone, limitMinor: 100_000, period: .monthly))
    let form = ExpenseForm(mode: .create, options: try await MoneyFixture.options(context), context: context, locale: BudgetFixture.english)
    let pick = try #require(form.budget)
    #expect(pick.choices(on: TestClock.day0).map(\.id) == [HomeBudget.id, kroner], "the trip does not cover today")
    #expect(Set(pick.choices(on: TestClock.day(3)).map(\.id)) == [HomeBudget.id, trip, kroner])

    let expect = { (currency: CurrencyCode, day: Int, budget: UUID, reason: BudgetAssignment.Reason) in
      let assignment = pick.assignment(currency: currency, on: TestClock.day(day))
      #expect(assignment == BudgetAssignment(budget: budget, reason: reason), "\(currency.code) on day \(day)")
    }
    expect(MoneyFixture.euro, 0, HomeBudget.id, .home)
    expect(MoneyFixture.krone, 0, kroner, .currency)
    expect(MoneyFixture.krone, 3, trip, .trip)
    expect(MoneyFixture.yen, 0, HomeBudget.id, .home)
    #expect(pick.explanation(currency: MoneyFixture.yen, on: TestClock.day0, locale: BudgetFixture.english).contains("converted"))
    #expect(pick.explanation(currency: MoneyFixture.euro, on: TestClock.day0, locale: BudgetFixture.english).contains("converted") == false)
    #expect(pick.explanation(currency: MoneyFixture.euro, on: TestClock.day(3), locale: BudgetFixture.english) == "The trip covers this date.")
  }

  @Test("should save an override, say when its budget does not cover the date, and clear it back to the rule")
  func overridesAndClears() async throws {
    let context = try await MoneyFixture.context()
    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Lisbon", from: 0, through: 4))
    let form = ExpenseForm(mode: .create, options: try await MoneyFixture.options(context), context: context, locale: BudgetFixture.english)
    #expect(form.budget?.assignment(currency: MoneyFixture.euro, on: TestClock.day0).budget == trip)
    form.amountText = "12"
    form.budget?.override = HomeBudget.id
    #expect(form.budget?.explanation(currency: MoneyFixture.euro, on: TestClock.day0, locale: BudgetFixture.english) == "You chose this budget.")
    let id = try #require(await form.save())
    let saved = try #require(try await MoneyFixture.expenseEntries(context).first { $0.record.id == id }?.record)
    #expect(saved.budget == HomeBudget.id)

    let edit = ExpenseForm(mode: .edit(saved), options: try await MoneyFixture.options(context), context: context, locale: BudgetFixture.english)
    #expect(edit.budget?.override == HomeBudget.id && !edit.hasChanges)
    edit.budget?.override = trip
    edit.occurredOn = TestClock.day(-1)
    #expect(
      edit.budget?.explanation(currency: MoneyFixture.euro, on: TestClock.day(-1), locale: BudgetFixture.english) == "Lisbon doesn’t cover Mar 1, 2026, so this counts in Home.")
    edit.occurredOn = TestClock.day0
    edit.budget?.override = nil
    #expect(await edit.save() == id)
    #expect(try await MoneyFixture.expenseEntries(context).first?.record.budget == nil)
    #expect(try await MoneyFixture.changeRecords(context).last?.changes == [.budget(from: HomeBudget.id, to: nil)])
  }

  @Test("should refuse an override whose budget was deleted while the form was open, then fall back to the rule")
  func refusesADeletedBudget() async throws {
    let context = try await MoneyFixture.context()
    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Lisbon", from: 0, through: 4))
    let form = ExpenseForm(mode: .create, options: try await MoneyFixture.options(context), context: context, locale: BudgetFixture.english)
    form.amountText = "12"
    form.budget?.override = trip
    try await context.writer.write { _, transaction in try BudgetEdits.delete(trip, in: &transaction) }

    #expect(await form.save() == nil)
    #expect(form.failure?.headline == WritingErrors.presented(FinanceError.budgetAbsent(trip))?.headline)
    #expect(try await MoneyFixture.expenseEntries(context).isEmpty)
    #expect(form.budget?.override == nil)
    #expect(form.budget?.choices(on: TestClock.day0).map(\.id) == [HomeBudget.id])
    #expect(await form.save() != nil)
  }

  @Test("should leave an override naming a deleted budget as it was when the owner does not touch the chip")
  func keepsAnUntouchedDeadOverride() async throws {
    let context = try await MoneyFixture.context()
    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Lisbon", from: 0, through: 4))
    let expense = ExpenseRecord(
      id: UUID.v7(at: context.clock.now()), amountMinor: 500, currency: MoneyFixture.euro, occurredOn: TestClock.day0, category: MoneyFixture.food, budget: trip,
      loggedAtMillis: MemoirClock.millis(context.clock.now()))
    try await context.writer.write { issuer, transaction in
      _ = try ExpenseEdits.create(expense, issuer: issuer, in: &transaction)
      try BudgetEdits.delete(trip, in: &transaction)
    }
    let form = ExpenseForm(mode: .edit(expense), options: try await MoneyFixture.options(context), context: context, locale: BudgetFixture.english)
    #expect(form.budget?.override == nil)
    #expect(!form.hasChanges)
    form.note = "Snack"
    #expect(await form.save() == expense.id)
    #expect(try await MoneyFixture.expenseEntries(context).first?.record.budget == trip)
  }

  @Test("should give a subscription an override every cycle counts in, and keep a cycle expense's prefill from it")
  func overridesASubscription() async throws {
    let context = try await MoneyFixture.context()
    let kroner = try await BudgetFixture.create(context, BudgetDraft(name: "Kroner", currency: MoneyFixture.krone, limitMinor: 100_000, period: .monthly))
    let form = SubscriptionForm(options: try await MoneyFixture.options(context), context: context, locale: BudgetFixture.english)
    form.name = "Music"
    form.amountText = "11.99"
    form.budget?.override = kroner
    let id = try #require(await form.save())
    #expect(try await MoneyFixture.subscriptions(context).first?.record.budget == kroner)

    let edit = try #require(try await SubscriptionForm.load(id, context: context, locale: BudgetFixture.english))
    #expect(edit.budget?.override == kroner && !edit.hasChanges)
    edit.budget?.override = nil
    #expect(await edit.save() == id)
    #expect(try await MoneyFixture.subscriptions(context).first?.record.budget == nil)

    let again = try #require(try await SubscriptionForm.load(id, context: context, locale: BudgetFixture.english))
    again.budget?.override = kroner
    #expect(await again.save() == id)
    let confirmation = CycleConfirmation(subscription: id, billingDate: TestClock.day0)
    try await context.writer.write { issuer, transaction in _ = try issuer.confirmCycle(confirmation, in: &transaction) }
    let cycle = try #require(try await MoneyFixture.expenseEntries(context).first?.record)
    let cycleForm = ExpenseForm(mode: .edit(cycle), options: try await MoneyFixture.options(context), context: context, locale: BudgetFixture.english)
    #expect(cycleForm.subscriptionOverride == kroner)
    let assignment = try #require(cycleForm.budget?.assignment(currency: cycle.currency, on: cycle.occurredOn, subscriptionOverride: cycleForm.subscriptionOverride))
    #expect(assignment == BudgetAssignment(budget: kroner, reason: .subscriptionOverride))
  }

  @Test("should name the budgets an expense moved between in its history")
  func namesTheBudgetInHistory() async throws {
    let context = try await MoneyFixture.context()
    let trip = try await BudgetFixture.create(context, BudgetFixture.trip("Lisbon", from: 0, through: 4))
    let expense = try await MoneyFixture.expense(context, 1_000)
    let form = ExpenseForm(mode: .edit(expense), options: try await MoneyFixture.options(context), context: context, locale: BudgetFixture.english)
    form.budget?.override = trip
    #expect(await form.save() == expense.id)
    let back = ExpenseForm(
      mode: .edit(try #require(try await MoneyFixture.expenseEntries(context).first?.record)), options: try await MoneyFixture.options(context), context: context,
      locale: BudgetFixture.english)
    back.budget?.override = HomeBudget.id
    #expect(await back.save() == expense.id)

    let detail = ExpenseDetailModel(id: expense.id, context: context)
    let running = Task { await detail.run() }
    defer { running.cancel() }
    try await TestClock.until("the detail") { detail.expense?.budget == HomeBudget.id && detail.budgets.state.value?.isEmpty == false }
    let lines = detail.historyLines(locale: BudgetFixture.english).map(\.text)
    #expect(lines.contains("Budget added: Lisbon"))
    #expect(lines.contains("Budget Lisbon → Home"))
    #expect(detail.budgetName(UUID()) == "A budget not on this device")
  }
}
