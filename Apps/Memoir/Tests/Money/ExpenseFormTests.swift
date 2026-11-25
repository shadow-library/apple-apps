import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("ExpenseForm", TestTimeLimit.standard)
struct ExpenseFormTests {
  @Test("should create an expense and its command, reading the amount in the owner's locale")
  func createsAnExpense() async throws {
    let context = try await MoneyFixture.context()
    let form = ExpenseForm(mode: .create, options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.german)
    #expect(form.currency == MoneyFixture.euro)
    #expect(form.category == MoneyFixture.uncategorised)
    #expect(!form.canSave, "nothing typed yet")
    #expect(form.amountIssue == nil, "an empty field is not marked")

    form.amountText = "1.234,50"
    form.note = "  Lunch  "
    form.category = MoneyFixture.food
    let id = try #require(await form.save())

    let entries = try await MoneyFixture.expenseEntries(context)
    #expect(entries.map(\.record.id) == [id])
    let expense = try #require(entries.first?.record)
    #expect(expense.amountMinor == 123_450)
    #expect(expense.note == "Lunch")
    #expect(expense.merchant == nil)
    #expect(expense.category == MoneyFixture.food)
    #expect(expense.occurredOn == TestClock.day0)
    #expect(try await MoneyFixture.bodies(context) == [.expenseCreate(ExpenseCreation(id: id, occurredOn: expense.occurredOn))])
  }

  @Test("should refuse amounts past the currency's places, with none for the yen and three for the dinar")
  func refusesTooPreciseAmounts() async throws {
    let context = try await MoneyFixture.context(enabled: [MoneyFixture.euro, MoneyFixture.yen, MoneyFixture.dinar])
    let form = ExpenseForm(mode: .create, options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)

    form.select(MoneyFixture.yen)
    form.amountText = "12.5"
    #expect(form.amount == .failure(.tooPrecise(allowedPlaces: 0)))
    #expect(form.amountIssue == MoneyLabels.amountIssue(.tooPrecise(allowedPlaces: 0), currency: MoneyFixture.yen, format: form.format))
    #expect(form.amountIssue?.contains("JPY") == true)
    #expect(!form.canSave)
    form.amountText = "1,840.00"
    #expect(form.amount == .success(1840))

    form.select(MoneyFixture.dinar)
    form.amountText = "1.2345"
    #expect(form.amount == .failure(.tooPrecise(allowedPlaces: 3)))
    #expect(form.amountIssue?.contains("3") == true)
    form.amountText = "1.234"
    #expect(form.amount == .success(1234))
    #expect(form.canSave)

    form.amountText = "-5"
    #expect(form.amount == .failure(.negative))
    #expect(form.amountIssue != nil)
    form.amountText = "1,5"
    #expect(form.amount == .failure(.misplacedGrouping), "an English grouping separator is never read as a decimal one")
    #expect(await form.save() == nil)
    #expect(try await MoneyFixture.expenseEntries(context).isEmpty)
  }

  @Test("should keep a saved expense's currency, and show the reference's wording when the core refuses to move it")
  func locksTheCurrency() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await MoneyFixture.expense(context, 29_900, MoneyFixture.krone, note: "Train")
    let form = ExpenseForm(mode: .edit(expense), options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)
    #expect(!form.canChangeCurrency)
    #expect(form.amountText == "299.00")
    #expect(!form.canSave, "nothing changed yet")

    form.select(MoneyFixture.euro)
    #expect(form.currency == MoneyFixture.krone)
    form.amountText = "310"
    #expect(await form.save() == expense.id)
    let saved = try #require(try await MoneyFixture.expenseEntries(context).first?.record)
    #expect(saved.currency == MoneyFixture.krone)
    #expect(saved.amountMinor == 31_000)

    do {
      try await context.writer.write { issuer, transaction in
        _ = try ExpenseEdits.update(expense.id, issuer: issuer, in: &transaction) { $0.currency = MoneyFixture.euro }
      }
      Issue.record("moving the currency was written")
    } catch {
      #expect(WritingErrors.presented(error)?.headline == String(localized: "A saved expense’s currency can’t be changed. Delete it and add it again.", table: "Writing"))
    }
  }

  @Test("should edit through a change record, and delete clearing the words and purging the change records")
  func editsAndDeletes() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await MoneyFixture.expense(context, 1840, note: "Lunch", merchant: "Café")
    let form = ExpenseForm(mode: .edit(expense), options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)
    form.amountText = "20.00"
    form.merchant = ""
    #expect(await form.save() == expense.id)

    let changes = try await MoneyFixture.changeRecords(context)
    #expect(changes.map(\.changes) == [[.amount(from: 1840, to: 2000), .merchant(from: "Café", to: nil)]])
    #expect(try await MoneyFixture.bodies(context).last == .expenseUpdate(RecordReference(id: expense.id)))

    let detail = ExpenseDetailModel(id: expense.id, context: context)
    let running = Task { await detail.run() }
    defer { running.cancel() }
    try await TestClock.until("the detail") { detail.expense?.amountMinor == 2000 && detail.book.state.value != nil }
    let lines = detail.historyLines(locale: MoneyFixture.english).map(\.text)
    #expect(lines.contains(String(localized: "Created", table: "Money")))
    #expect(lines.count == 3, "created, and the amount and merchant of the edit")

    await detail.delete()
    #expect(detail.failure == nil)
    let entry = try #require(try await MoneyFixture.expenseEntries(context).first)
    #expect(entry.isRemoved)
    #expect(entry.record.note == nil && entry.record.merchant == nil)
    #expect(try await MoneyFixture.changeRecords(context).isEmpty)
    #expect(try await MoneyFixture.bodies(context).last == .expenseDelete(RecordReference(id: expense.id)))
    try await TestClock.until("the deleted detail") { detail.expense == nil }
    #expect(detail.deletion?.canUndo == true)
  }

  @Test("should undo a delete by creating the expense again with its words, rate and logging time")
  func undoesADelete() async throws {
    let context = try await MoneyFixture.context()
    let rate = FxRateRecord(base: MoneyFixture.krone, quote: MoneyFixture.euro, date: TestClock.day0, rate: try #require(DecimalText("0.1")))
    try await context.writer.write { _, transaction in _ = try rate.create(in: &transaction) }
    let expense = try await MoneyFixture.expense(context, 29_900, MoneyFixture.krone, note: "Train", merchant: "NSB")
    #expect(expense.rate?.rate == rate.rate, "the rate is captured when written")
    let detail = ExpenseDetailModel(id: expense.id, context: context)
    let running = Task { await detail.run() }
    defer { running.cancel() }
    try await TestClock.until("the detail") { detail.expense != nil && detail.book.state.value != nil }
    #expect(detail.inHome == .converted(2990))
    #expect(detail.rate == rate.rate)

    await detail.delete()
    try await TestClock.until("the deleted detail") { detail.expense == nil }
    #expect(detail.deletion?.snapshot == expense, "the deletion shows until the read catches up, never as gone")
    #expect(!detail.isGone)
    await detail.undo()

    #expect(detail.failure == nil)
    let restored = try #require(try await MoneyFixture.expenseEntries(context).first)
    #expect(!restored.isRemoved)
    #expect(restored.record == expense)
    let creations = try await MoneyFixture.bodies(context).filter { $0 == .expenseCreate(ExpenseCreation(id: expense.id, occurredOn: expense.occurredOn)) }
    #expect(creations.count == 2)
    try await TestClock.until("the restored detail") { detail.expense?.note == "Train" }
    #expect(detail.deletion == nil)

    try await context.writer.write { issuer, transaction in _ = try ExpenseEdits.delete(expense.id, issuer: issuer, in: &transaction) }
    try await TestClock.until("the delete from another writer") { detail.expense == nil }
    #expect(detail.isGone, "a delete made elsewhere shows as no longer here")
    #expect(detail.deletion == nil, "and offers no undo")
    await detail.undo()
    #expect(try await MoneyFixture.expenseEntries(context).first?.isRemoved == true, "undo writes nothing")
  }

  @Test("should not offer undo for the expense a confirmed subscription cycle wrote")
  func refusesUndoForACycleExpense() async throws {
    let context = try await MoneyFixture.context()
    let form = SubscriptionForm(options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)
    form.name = "Music"
    form.amountText = "11.99"
    let subscription = try #require(await form.save())
    let confirmation = CycleConfirmation(subscription: subscription, billingDate: TestClock.day0)
    _ = try await context.writer.write { issuer, transaction in try issuer.confirmCycle(confirmation, in: &transaction).expense }
    let detail = ExpenseDetailModel(id: SubscriptionCycles.expenseID(for: confirmation), context: context)
    let running = Task { await detail.run() }
    defer { running.cancel() }
    try await TestClock.until("the cycle's expense") { detail.expense != nil && detail.isCycleExpense }
    #expect(!detail.canUndoDelete)

    await detail.delete()
    try await TestClock.until("the deleted detail") { detail.expense == nil }
    #expect(detail.deletion?.canUndo == false)
    await detail.undo()
    #expect(try await MoneyFixture.expenseEntries(context).first?.isRemoved == true, "undo writes nothing")
  }

  @Test("should show that an expense deleted elsewhere is gone")
  func showsAGoneExpense() async throws {
    let context = try await MoneyFixture.context()
    let detail = ExpenseDetailModel(id: UUID(), context: context)
    let running = Task { await detail.run() }
    defer { running.cancel() }
    try await TestClock.until("the history") { detail.history.state.value != nil }
    #expect(detail.isGone)
    #expect(!detail.canUndoDelete)
    await detail.delete()
    #expect(try await MoneyFixture.bodies(context).isEmpty)
  }

  @Test("should let the owner enter, correct and clear a pending expense's rate, refusing one that does not read")
  func entersARateByHand() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await MoneyFixture.expense(context, 10_000, MoneyFixture.krone, note: "Ferry")
    let detail = ExpenseDetailModel(id: expense.id, context: context)
    let running = Task { await detail.run() }
    defer { running.cancel() }
    try await TestClock.until("the pending detail") { detail.expense != nil && detail.book.state.value != nil }
    #expect(detail.isAwaitingRate)

    let form = ExpenseForm(mode: .edit(expense), options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.german)
    #expect(form.offersRate)
    #expect(form.rateText.isEmpty)
    form.rateText = "0"
    #expect(form.rateIssue == MoneyLabels.rateIssue(.notPositive, format: form.format))
    #expect(!form.canSave)
    form.rateText = "0,123456789"
    #expect(form.manualRate == .failure(.tooPrecise(allowedPlaces: 8)))
    form.rateText = "0,09"
    #expect(form.rateIssue == nil)
    #expect(await form.save() == expense.id)
    try await TestClock.until("the entered rate") { detail.inHome == .converted(900) }
    #expect(detail.isManualRate)
    #expect(!detail.isAwaitingRate)
    #expect(detail.rate?.text == "0.09")

    let edited = try #require(detail.expense)
    let correction = ExpenseForm(mode: .edit(edited), options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.german)
    #expect(correction.rateText == "0,09")
    correction.rateText = ""
    #expect(await correction.save() == expense.id)
    try await TestClock.until("the cleared rate") { detail.isAwaitingRate }
    let lines = detail.historyLines(locale: MoneyFixture.english).map(\.text)
    #expect(lines.contains("Rate you entered added: 0.09"))
    #expect(lines.contains("Rate you entered removed (was 0.09)"))
  }

  @Test("should describe a refund as one line with its amounts and the savings draw it returned, without a second amount line")
  func describesARefund() async throws {
    let context = try await MoneyFixture.context()
    let expense = ExpenseRecord(
      id: UUID.v7(at: context.clock.now()), amountMinor: 2000, currency: MoneyFixture.euro, occurredOn: TestClock.day0, category: MoneyFixture.food,
      fromSavingsMinor: 1800, loggedAtMillis: MemoirClock.millis(context.clock.now()))
    let id = expense.id
    _ = try await context.writer.write { _, transaction in try expense.create(in: &transaction) }
    _ = try await context.writer.write { issuer, transaction in try ExpenseEdits.refund(id, amount: .partial(500), issuer: issuer, in: &transaction) }

    let detail = ExpenseDetailModel(id: id, context: context)
    let running = Task { await detail.run() }
    defer { running.cancel() }
    try await TestClock.until("the refunded detail") { detail.expense?.amountMinor == 1500 && detail.book.state.value != nil }
    let lines = detail.historyLines(locale: MoneyFixture.english).map(\.text)
    let refund = try #require(lines.firstIndex(of: "Refund: €20.00 → €15.00"))
    #expect(lines[refund + 1] == "From savings €18.00 → €15.00")
    #expect(!lines.contains { $0.hasPrefix("Amount") }, "the refund line already says the amount")
  }

  @Test("should offer no rate for an expense in the home currency")
  func offersNoRateAtHome() async throws {
    let context = try await MoneyFixture.context()
    let form = ExpenseForm(mode: .create, options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)
    #expect(!form.offersRate)
    form.rateText = "nonsense"
    form.amountText = "5"
    #expect(form.manualRate == .success(nil))
    let id = try #require(await form.save())
    #expect(try await MoneyFixture.expenseEntries(context).first { $0.record.id == id }?.record.manualRate == nil)
  }

  @Test("should keep a saved rate the field cannot show unless the owner edits the field")
  func keepsARateIntoAnotherHome() async throws {
    let context = try await MoneyFixture.context(home: MoneyFixture.krone, enabled: [MoneyFixture.krone, MoneyFixture.yen])
    let manual = ManualRate(rate: DecimalText("0.0062")!, quote: MoneyFixture.euro)
    let expense = ExpenseRecord(
      id: UUID.v7(at: context.clock.now()), amountMinor: 1_000, currency: MoneyFixture.yen, occurredOn: TestClock.day0, category: MoneyFixture.food, note: "Tea",
      manualRate: manual, loggedAtMillis: MemoirClock.millis(context.clock.now()))
    _ = try await context.writer.write { issuer, transaction in try ExpenseEdits.create(expense, issuer: issuer, in: &transaction) }
    let options = try await MoneyFixture.options(context)

    let form = ExpenseForm(mode: .edit(expense), options: options, context: context, locale: MoneyFixture.english)
    #expect(form.rateText.isEmpty, "a rate into the euro is not this vault's krone")
    #expect(!form.hasChanges)
    #expect(form.manualRate == .success(manual))
    form.note = "Green tea"
    #expect(await form.save() == expense.id)
    let saved = try #require(try await MoneyFixture.expenseEntries(context).first?.record)
    #expect(saved.note == "Green tea")
    #expect(saved.manualRate == manual, "editing the note keeps the rate")
  }

  @Test("should clear a typed rate when the currency changes")
  func clearsTheRateWithTheCurrency() async throws {
    let context = try await MoneyFixture.context(enabled: [MoneyFixture.euro, MoneyFixture.krone, MoneyFixture.yen])
    let form = ExpenseForm(mode: .create, options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)
    form.select(MoneyFixture.krone)
    form.rateText = "0.0875"
    form.select(MoneyFixture.krone)
    #expect(form.rateText == "0.0875", "choosing the same currency keeps it")
    form.select(MoneyFixture.yen)
    #expect(form.rateText.isEmpty)
    form.rateText = "0.0062"
    form.select(MoneyFixture.euro)
    #expect(form.rateText.isEmpty)
    #expect(form.manualRate == .success(nil))
  }
}
