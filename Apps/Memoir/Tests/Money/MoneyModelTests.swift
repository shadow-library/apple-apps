import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("MoneyModel", TestTimeLimit.standard)
struct MoneyModelTests {
  @Test("should load the overview and emit again when an expense is written")
  func loadsAndReemits() async throws {
    let context = try await MoneyFixture.context(budgetMinor: 50_000)
    let model = MoneyModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }

    let empty = try await MoneyFixture.loaded(model.overview, "the empty overview") { $0 != nil }
    #expect(empty?.month.spent.totalMinor == 0)
    #expect(empty?.homeBudget?.leftMinor == 50_000)

    try await MoneyFixture.expense(context, 1840, note: "Lunch")
    let spent = try await MoneyFixture.loaded(model.overview, "the overview with the lunch") { $0?.month.spent.totalMinor == 1840 }
    #expect(spent?.homeBudget?.leftMinor == 48_160)
    #expect(spent?.week.daysLogged == 1)
    let listing = try await MoneyFixture.loaded(model.list.listing, "the list with the lunch") { $0.rows.total == 1 }
    #expect(listing.rows.items.map(\.expense.note) == ["Lunch"])
  }

  @Test("should show nothing to total before the vault has a base currency")
  func waitsForABaseCurrency() async throws {
    let context = try await MoneyFixture.context(home: nil)
    let model = MoneyModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }

    try await TestClock.until("the overview") { model.overview.state.value != nil }
    #expect(model.overview.state == .loaded(nil))
    let options = try await MoneyFixture.options(context)
    #expect(options.home == nil)
    #expect(options.currencies(including: nil).first == MoneyFixture.euro, "memoir-web's list still offers its currencies")
  }

  @Test("should leave an expense waiting for a rate out of the totals, count it, and show its rate as pending")
  func leavesRatePendingExpensesOut() async throws {
    let context = try await MoneyFixture.context()
    try await MoneyFixture.expense(context, 1000)
    try await MoneyFixture.expense(context, 29_900, MoneyFixture.krone, note: "Train")
    let model = MoneyModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }

    let overview = try #require(try await MoneyFixture.loaded(model.overview, "the overview") { $0 != nil })
    #expect(overview.month.spent.totalMinor == 1000)
    #expect(overview.month.spent.pending.awaitingRate == 1)
    #expect(overview.month.spent.pending.currencies == [MoneyFixture.krone])
    let note = try #require(MoneyNotes.pending(overview.month.spent.pending))
    #expect(note.contains("1"))
    #expect(MoneyNotes.pending(.none) == nil)
    #expect(overview.homeBudget == nil)
    #expect(overview.month.categories.first { $0.category == MoneyFixture.food }?.pending.awaitingRate == 1)
    #expect(MoneyNotes.leftOut(overview.month.spent.pending) == [String(localized: "\(1) rate pending", table: "Money")])

    let listing = try await MoneyFixture.loaded(model.list.listing, "both rows") { $0.rows.total == 2 }
    let train = try #require(listing.rows.items.first { $0.expense.note == "Train" })
    let content = ExpenseRowContent(train, home: listing.home, categoryName: { MoneyLabels.categoryName($0) }, locale: MoneyFixture.english)
    #expect(content.isRatePending)
    #expect(content.secondary == String(localized: "Rate pending", table: "Money"))
    #expect(content.amount == MoneyText.formatted(29_900, MoneyFixture.krone, locale: MoneyFixture.english))

    let rate = FxRateRecord(base: MoneyFixture.krone, quote: MoneyFixture.euro, date: TestClock.day0, rate: try #require(DecimalText("0.1")))
    try await context.writer.write { _, transaction in _ = try rate.create(in: &transaction) }
    let converted = try await MoneyFixture.loaded(model.overview, "the overview with the rate") { $0?.month.spent.totalMinor == 3990 }
    #expect(converted?.month.spent.pending == PendingConversions.none)
  }

  @Test("should page, search and filter the list, and restart it when the range changes")
  func pagesSearchesAndFilters() async throws {
    let context = try await MoneyFixture.context()
    for index in 0..<10 {
      try await MoneyFixture.expense(
        context, Int64(100 + index), category: index < 3 ? MoneyFixture.transport : MoneyFixture.food, note: index == 4 ? "Coffee beans" : "Item \(index)")
    }
    try await MoneyFixture.expense(context, 999, on: TestClock.day(-10), note: "Last month")
    let model = MoneyModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }

    let first = try await MoneyFixture.loaded(model.list.listing, "the first page") { $0.rows.total == 10 }
    #expect(first.rows.items.count == ExpenseListModel.overviewPageSize)
    #expect(first.rows.hasMore)

    model.list.showMore()
    let all = try await MoneyFixture.loaded(model.list.listing, "the second page") { $0.rows.items.count == 10 }
    #expect(!all.rows.hasMore)

    model.list.search = "COFFEE"
    let searched = try await MoneyFixture.loaded(model.list.listing, "the search") { $0.rows.total == 1 }
    #expect(searched.rows.items.first?.expense.note == "Coffee beans")
    #expect(model.list.limit == ExpenseListModel.overviewPageSize, "a new search starts from the first page")
    let scope = ExpenseListScope(range: .month, search: "COFFEE", category: nil)
    #expect(model.list.scope == scope)
    let shown = ExpenseListModel(context: context, scope: scope)
    let running2 = Task { await shown.run() }
    defer { running2.cancel() }
    let all2 = try await MoneyFixture.loaded(shown.listing, "the full list of the same scope") { $0.rows.total == 1 }
    #expect(all2.rows.items.first?.expense.note == "Coffee beans")

    model.list.search = ""
    model.list.category = MoneyFixture.transport
    let filtered = try await MoneyFixture.loaded(model.list.listing, "the category") { $0.rows.total == 3 }
    #expect(filtered.rows.items.allSatisfy { $0.expense.category == MoneyFixture.transport })

    model.list.category = nil
    model.range = .year
    _ = try await MoneyFixture.loaded(model.list.listing, "the year") { $0.rows.total == 11 }
    model.range = .week
    _ = try await MoneyFixture.loaded(model.list.listing, "the week") { $0.rows.total == 10 }
  }

  @Test("should name the next subscription in the subscriptions note and count unconverted ones")
  func describesSubscriptions() async throws {
    let context = try await MoneyFixture.context()
    let options = try await MoneyFixture.options(context)
    let form = SubscriptionForm(options: options, context: context, locale: MoneyFixture.english)
    form.name = "Music"
    form.amountText = "11.99"
    form.nextDue = TestClock.day(3)
    #expect(await form.save() != nil)
    let model = MoneyModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }

    let overview = try #require(try await MoneyFixture.loaded(model.overview, "the overview") { $0?.subscriptions.activeCount == 1 })
    _ = try await MoneyFixture.loaded(model.subscriptions, "the subscriptions") { $0?.items.count == 1 }
    let note = MoneyNotes.subscriptions(overview, name: model.subscriptionName, locale: MoneyFixture.english)
    #expect(note.contains("Music"))
    #expect(overview.subscriptions.monthlyMinor == 1199)

    let cloud = SubscriptionForm(options: options, context: context, locale: MoneyFixture.english)
    cloud.name = "Cloud"
    cloud.amountText = "99"
    cloud.currency = MoneyFixture.krone
    #expect(await cloud.save() != nil)
    let unconverted = try #require(try await MoneyFixture.loaded(model.overview, "the krone subscription") { $0?.subscriptions.pending.count == 1 })
    #expect(unconverted.subscriptions.monthlyMinor == 1199, "the krone subscription has no rate and adds nothing")
    #expect(MoneyNotes.subscriptions(unconverted, name: model.subscriptionName, locale: MoneyFixture.english).contains("NOK"))
  }
}
