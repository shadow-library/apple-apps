import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("Refund", TestTimeLimit.standard)
struct RefundTests {
  private func model(_ expense: ExpenseRecord, _ context: MemoirScreenContext, locale: Locale = MoneyFixture.english) -> RefundModel {
    RefundModel(expense: expense, context: context, locale: locale)
  }

  private func savingsExpense(_ context: MemoirScreenContext, amount: Int64, fromSavings: Int64) async throws -> ExpenseRecord {
    let expense = ExpenseRecord(
      id: UUID.v7(at: context.clock.now()), amountMinor: amount, currency: MoneyFixture.euro, occurredOn: TestClock.day0, category: MoneyFixture.food,
      fromSavingsMinor: fromSavings, loggedAtMillis: MemoirClock.millis(context.clock.now()))
    return try await context.writer.write { issuer, transaction in try ExpenseEdits.create(expense, issuer: issuer, in: &transaction).expense }
  }

  private func current(_ id: UUID, _ context: MemoirScreenContext) async throws -> ExpenseRecord {
    try #require(try await MoneyFixture.expenseEntries(context).first { $0.record.id == id }?.record)
  }

  @Test("should refund the whole amount, leaving the expense at zero with a refund change record")
  func refundsInFull() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await MoneyFixture.expense(context, 2000)
    let refund = model(expense, context)
    #expect(refund.canSave)
    #expect(await refund.save())
    #expect(refund.failure == nil)
    #expect(try await current(expense.id, context).amountMinor == 0)
    #expect(try await MoneyFixture.changeRecords(context).last?.reason == .known(.refund))
  }

  @Test("should refund the typed part, read in the owner's locale")
  func refundsPartly() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await MoneyFixture.expense(context, 123_450)
    let refund = model(expense, context, locale: MoneyFixture.german)
    refund.mode = .partial
    #expect(!refund.canSave, "nothing typed yet")
    #expect(refund.amountIssue == nil)
    refund.amountText = "1.000,50"
    #expect(refund.refundMinor == .success(100_050))
    #expect(await refund.save())
    #expect(try await current(expense.id, context).amountMinor == 23_400)
  }

  @Test("should refuse a partial refund of zero, past what is left, and past the currency's places, each with copy before saving")
  func refusesInvalidAmounts() async throws {
    let context = try await MoneyFixture.context(enabled: [MoneyFixture.euro, MoneyFixture.yen])
    let expense = try await MoneyFixture.expense(context, 2000)
    let refund = model(expense, context)
    refund.mode = .partial

    refund.amountText = "0"
    #expect(refund.refundMinor == .failure(.notPositive))
    #expect(refund.amountIssue == "A refund has to be more than zero.")
    #expect(!refund.canSave)

    refund.amountText = "20.01"
    #expect(refund.refundMinor == .failure(.exceeds(left: 2000)))
    #expect(refund.amountIssue == "That is more than the €20.00 left on this expense.")
    #expect(!refund.canSave)

    refund.amountText = "1.234"
    #expect(refund.amountIssue == MoneyLabels.amountIssue(.tooPrecise(allowedPlaces: 2), currency: MoneyFixture.euro, format: refund.format))

    refund.amountText = "abc"
    #expect(refund.amountIssue != nil)
    #expect(await refund.save() == false)
    #expect(try await current(expense.id, context).amountMinor == 2000)

    let yen = try await MoneyFixture.expense(context, 1840, MoneyFixture.yen)
    let yenRefund = model(yen, context)
    yenRefund.mode = .partial
    yenRefund.amountText = "12.5"
    #expect(yenRefund.amountIssue?.contains("JPY") == true)
    yenRefund.amountText = "1840"
    #expect(yenRefund.canSave, "the whole amount as a partial refund is allowed and is a full one")
  }

  @Test("should show a write failure and keep the sheet open when the expense changed under it")
  func showsWriteFailures() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await MoneyFixture.expense(context, 2000)
    let refund = model(expense, context)
    refund.mode = .partial
    refund.amountText = "15"
    let id = expense.id
    _ = try await context.writer.write { issuer, transaction in try ExpenseEdits.refund(id, amount: .partial(1000), issuer: issuer, in: &transaction) }

    #expect(refund.canSave, "the sheet still holds the amount it opened with")
    #expect(await refund.save() == false)
    #expect(refund.failure?.headline == "That refund is more than what’s left on the expense.")
    #expect(try await current(id, context).amountMinor == 1000)
    refund.amountText = "5"
    #expect(refund.failure == nil, "typing again clears the refusal")
    #expect(await refund.save())
    #expect(try await current(id, context).amountMinor == 500)
  }

  @Test("should refuse a full refund of an expense another device refunded in full meanwhile")
  func refusesWhatIsAlreadyRefunded() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await MoneyFixture.expense(context, 2000)
    let refund = model(expense, context)
    let id = expense.id
    _ = try await context.writer.write { issuer, transaction in try ExpenseEdits.refund(id, amount: .full, issuer: issuer, in: &transaction) }
    #expect(await refund.save() == false)
    #expect(refund.failure?.headline == "There’s nothing left to refund on this expense.")
    #expect(try await MoneyFixture.changeRecords(context).count == 1)
  }

  @Test("should say how much returns to savings, only when the refund leaves less than the savings draw")
  func explainsSavings() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await savingsExpense(context, amount: 2000, fromSavings: 1800)
    let refund = model(expense, context)
    #expect(refund.returnedToSavings == 1800)
    refund.mode = .partial
    #expect(refund.returnedToSavings == nil, "nothing typed")
    refund.amountText = "1"
    #expect(refund.returnedToSavings == nil, "1900 left still holds the 1800 draw")
    refund.amountText = "5"
    #expect(refund.returnedToSavings == 300)
    #expect(await refund.save())
    let after = try await current(expense.id, context)
    #expect(after.amountMinor == 1500)
    #expect(after.fromSavingsMinor == 1500)

    let plain = model(try await MoneyFixture.expense(context, 500), context)
    #expect(plain.returnedToSavings == nil)
  }

  @Test("should refund an expense with a receipt, a note and another currency in its own currency")
  func refundsForeignExpenses() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await MoneyFixture.expense(context, 29_900, MoneyFixture.krone, note: "Train")
    let refund = model(expense, context)
    #expect(refund.currency == MoneyFixture.krone)
    refund.mode = .partial
    refund.amountText = "100"
    #expect(await refund.save())
    let after = try await current(expense.id, context)
    #expect(after.amountMinor == 19_900)
    #expect(after.note == "Train")
  }

  @Test("should show the refund state on rows and on the detail from the change records, never from a zero amount")
  func presentsRefundState() async throws {
    let context = try await MoneyFixture.context()
    let partly = try await MoneyFixture.expense(context, 2000, note: "Partly")
    let fully = try await MoneyFixture.expense(context, 1000, note: "Fully")
    let free = try await MoneyFixture.expense(context, 0, note: "Free trial")
    let untouched = try await MoneyFixture.expense(context, 300, note: "Untouched")
    let partlyID = partly.id
    let fullyID = fully.id
    try await context.writer.write { issuer, transaction in
      try ExpenseEdits.refund(partlyID, amount: .partial(500), issuer: issuer, in: &transaction)
      try ExpenseEdits.refund(fullyID, amount: .full, issuer: issuer, in: &transaction)
    }

    let list = MoneyModel(context: context)
    let running = Task { await list.run() }
    defer { running.cancel() }
    let listing = try await MoneyFixture.loaded(list.list.listing, "four rows") { $0.rows.total == 4 }
    func content(_ note: String) throws -> ExpenseRowContent {
      let row = try #require(listing.rows.items.first { $0.expense.note == note })
      return ExpenseRowContent(row, home: listing.home, categoryName: { MoneyLabels.categoryName($0) }, locale: MoneyFixture.english)
    }
    #expect(try content("Partly").refund == "Refunded €5.00")
    #expect(try content("Fully").refund == "Refunded")
    #expect(try content("Free trial").refund == nil)
    #expect(try content("Untouched").refund == nil)
    _ = (free, untouched)

    let detail = ExpenseDetailModel(id: partlyID, context: context)
    let detailRunning = Task { await detail.run() }
    defer { detailRunning.cancel() }
    try await TestClock.until("the refunded detail") { detail.refund != nil }
    #expect(detail.refund == .partial(refundedMinor: 500))
    #expect(detail.amountBeforeRefund == 2000)
    #expect(detail.canRefund)

    let fullDetail = ExpenseDetailModel(id: fullyID, context: context)
    let fullRunning = Task { await fullDetail.run() }
    defer { fullRunning.cancel() }
    try await TestClock.until("the fully refunded detail") { fullDetail.refund != nil }
    #expect(fullDetail.refund == .full)
    #expect(fullDetail.amountBeforeRefund == 1000)
    #expect(!fullDetail.canRefund)

    let freeDetail = ExpenseDetailModel(id: free.id, context: context)
    let freeRunning = Task { await freeDetail.run() }
    defer { freeRunning.cancel() }
    try await TestClock.until("the free detail") { freeDetail.expense != nil && freeDetail.book.state.value != nil }
    #expect(freeDetail.refund == nil)
    #expect(!freeDetail.canRefund)
  }

  @Test("should word a partial and a full refund in the history, with the savings draw as its own line")
  func wordsHistory() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await savingsExpense(context, amount: 2000, fromSavings: 1800)
    let id = expense.id
    _ = try await context.writer.write { issuer, transaction in try ExpenseEdits.refund(id, amount: .partial(500), issuer: issuer, in: &transaction) }
    _ = try await context.writer.write { issuer, transaction in try ExpenseEdits.refund(id, amount: .full, issuer: issuer, in: &transaction) }

    let detail = ExpenseDetailModel(id: id, context: context)
    let running = Task { await detail.run() }
    defer { running.cancel() }
    try await TestClock.until("the refunded detail") { detail.expense?.amountMinor == 0 && detail.book.state.value != nil }
    let lines = detail.historyLines(locale: MoneyFixture.english).map(\.text)
    #expect(lines.contains("Refunded in full (€15.00 → €0.00)"))
    #expect(lines.contains("Refunded €5.00 (€20.00 → €15.00)"))
    #expect(lines.contains("From savings €18.00 → €15.00"))
    #expect(lines.contains("From savings removed (was €15.00)"))
  }
}
