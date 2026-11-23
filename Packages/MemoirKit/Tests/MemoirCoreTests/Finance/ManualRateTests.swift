import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Manual rates and rate requests", TestTimeLimit.quick)
struct ManualRateTests {
  private static let eur = MoneyReadsFixture.currency("EUR")
  private static let usd = MoneyReadsFixture.currency("USD")
  private static let nok = MoneyReadsFixture.currency("NOK")
  private static let english = AmountFormat(locale: Locale(identifier: "en_US"))
  private static let german = AmountFormat(locale: Locale(identifier: "de_DE"))

  private static func manual(_ text: String) -> ManualRate {
    ManualRate(rate: MoneyReadsFixture.decimal(text), quote: eur)
  }

  private static func refusal(_ text: String, _ format: AmountFormat) -> RateInputRefusal? {
    do throws(RateInputRefusal) {
      _ = try RateInput.rate(text, format: format)
      return nil
    } catch {
      return error
    }
  }

  @Test func shouldReadATypedRateExactlyInTheOwnersLocale() throws {
    #expect(try RateInput.rate("0.0934", format: Self.english).text.text == "0.0934")
    #expect(try RateInput.rate("0,0934", format: Self.german).text.text == "0.0934")
    #expect(try RateInput.rate(" 1.234,50 ", format: Self.german).text.text == "1234.5")
    #expect(try RateInput.rate("007.10000000", format: Self.english).text.text == "7.1")
    #expect(try RateInput.rate(".5", format: Self.english).text.text == "0.5")
    #expect(Self.refusal("0", Self.english) == .notPositive)
    #expect(Self.refusal("0.000000000", Self.english) == .notPositive)
    #expect(Self.refusal("-1", Self.english) == .unreadable(.negative))
    #expect(Self.refusal("0.123456789", Self.english) == .tooPrecise(allowedPlaces: 8))
    #expect(Self.refusal("1,5", Self.english) == .unreadable(.misplacedGrouping))
    #expect(Self.refusal("1.2.3", Self.english) == .unreadable(.repeatedDecimalSeparator))
    #expect(Self.refusal("12345678901234567890", Self.english) == .outOfRange)
  }

  @Test func shouldConvertAtTheOwnersRateAheadOfARecordedOrLockedOne() throws {
    let day = MoneyReadsFixture.date("2026-11-10")
    var expense = try FinanceFixture.expense(
      1, amountMinor: 10_000, currency: Self.usd, on: day, rate: ExpenseRate(rate: MoneyReadsFixture.decimal("0.95"), date: day, quote: Self.eur))
    let converter = HomeConverter(home: Self.eur, rates: [FxRateRecord(base: Self.usd, quote: Self.eur, date: day, rate: MoneyReadsFixture.decimal("0.9"))])
    #expect(converter.homeAmount(of: expense) == .converted(9_000))
    expense.manualRate = Self.manual("0.8")
    #expect(converter.homeAmount(of: expense) == .converted(8_000))
    #expect(converter.referenceRate(for: expense) == MoneyReadsFixture.decimal("0.9"))
    expense.manualRate = ManualRate(rate: MoneyReadsFixture.decimal("0.8"), quote: Self.nok)
    #expect(converter.homeAmount(of: expense) == .converted(9_000), "a rate into another currency than home is not used")
  }

  @Test func shouldNeverAskForNorLockAnExpenseTheOwnerGaveARate() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let day = MoneyReadsFixture.date("2026-11-10")
    try await store.write { transaction in
      try FinanceFixture.settings(home: Self.eur).create(in: &transaction)
      var typed = try FinanceFixture.expense(1, amountMinor: 10_000, currency: Self.usd, on: day)
      typed.manualRate = Self.manual("0.8")
      try typed.create(in: &transaction)
      try FinanceFixture.expense(2, amountMinor: 10_000, currency: Self.usd, on: day).create(in: &transaction)
    }
    let pair = CurrencyPair(base: Self.usd, quote: Self.eur)
    let client = ScriptedRatesClient([day: [pair: MoneyReadsFixture.decimal("0.9")]])
    let report = try await RateFiller(client: client).fill(store, today: FinanceFixture.today)
    #expect(client.requests.map(\.pairs) == [[pair]])
    #expect(report.filledExpenses == 1)
    let ledger = try await FinanceFixture.ledger(in: store)
    let converter = try #require(ledger.converter)
    let typed = try #require(ledger.expenses.first { $0.id == FinanceFixture.expenseID(1) })
    #expect(typed.rate == nil, "the filler never locks an expense the owner gave a rate")
    #expect(ledger.expenses.map { converter.homeAmount(of: $0) } == [.converted(8_000), .converted(9_000)])

    _ = try await store.write { transaction in try ExpenseRecord.edit(id: FinanceFixture.expenseID(1), in: &transaction) { $0.manualRate = nil } }
    let cleared = try await RateFiller(client: ScriptedRatesClient([:])).fill(store, today: FinanceFixture.today)
    #expect(cleared.filledExpenses == 1, "cleared, it locks the recorded rate of its day without asking")
    let after = try await FinanceFixture.ledger(in: store)
    let reverted = try #require(after.expenses.first { $0.id == FinanceFixture.expenseID(1) })
    #expect(reverted.rate == ExpenseRate(rate: MoneyReadsFixture.decimal("0.9"), date: day, quote: Self.eur))
    #expect(after.converter?.homeAmount(of: reverted) == .converted(9_000))
  }

  @Test func shouldAskYesterdaysRateForAnActiveForeignSubscriptionWithoutOne() throws {
    let today = MoneyReadsFixture.date("2026-11-21")
    let yesterday = MoneyReadsFixture.date("2026-11-20")
    let settings = FinanceFixture.settings(home: Self.eur)
    var subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 3, anchorOn: today, amountMinor: 999, currency: Self.usd)
    let none = FinanceLedger(settings: settings, expenses: [], rates: [], unreadable: 0)
    #expect(RateFiller.requests(none, subscriptions: [subscription], today: today).dates == [yesterday: [CurrencyPair(base: Self.usd, quote: Self.eur)]])

    let older = FinanceLedger(
      settings: settings, expenses: [], rates: [FxRateRecord(base: Self.usd, quote: Self.eur, date: MoneyReadsFixture.date("2026-01-02"), rate: MoneyReadsFixture.decimal("1.1"))],
      unreadable: 0)
    #expect(RateFiller.requests(older, subscriptions: [subscription], today: today).dates.keys.sorted() == [yesterday], "a rate older than a week is asked again")
    let recent = FinanceLedger(
      settings: settings, expenses: [], rates: [FxRateRecord(base: Self.usd, quote: Self.eur, date: MoneyReadsFixture.date("2026-11-15"), rate: MoneyReadsFixture.decimal("1.1"))],
      unreadable: 0)
    #expect(RateFiller.requests(recent, subscriptions: [subscription], today: today).isEmpty, "a rate from the last week converts it")
    let stale = FinanceLedger(
      settings: settings, expenses: [], rates: [FxRateRecord(base: Self.usd, quote: Self.eur, date: MoneyReadsFixture.date("2026-11-14"), rate: MoneyReadsFixture.decimal("1.1"))],
      unreadable: 0)
    #expect(!RateFiller.requests(stale, subscriptions: [subscription], today: today).isEmpty, "seven days old is no longer fresh")

    let asked = FinanceLedger(
      settings: settings, expenses: [try FinanceFixture.expense(1, amountMinor: 1, currency: Self.usd, on: MoneyReadsFixture.date("2026-11-02"))], rates: [], unreadable: 0)
    #expect(RateFiller.requests(asked, subscriptions: [subscription], today: today).dates.keys.sorted() == [MoneyReadsFixture.date("2026-11-02")])

    subscription.active = false
    #expect(RateFiller.requests(none, subscriptions: [subscription], today: today).isEmpty)
    #expect(RateFiller.requests(FinanceLedger(settings: nil, expenses: [], rates: [], unreadable: 0), subscriptions: [subscription], today: today) == .none)
  }

  @Test func shouldRecordTheOwnersRateInTheExpensesHistoryAndLetThemClearIt() async throws {
    let stores = try MemoirStores.openInMemory()
    let id = MoneyReadsFixture.id(1)
    let created = MoneyReadsFixture.expense(1, 1250, "USD", on: "2026-11-20")
    let issuer = MoneyReadsFixture.issuer(on: MoneyReadsFixture.date("2026-11-21"))
    try await MoneyReadsFixture.write(stores.main) { transaction in
      try FinanceFixture.settings(home: Self.eur).create(in: &transaction)
      try ExpenseEdits.create(created, issuer: issuer, in: &transaction)
    }
    for rate in [Self.manual("0.91"), Self.manual("0.92"), nil] {
      let command = try await stores.main.write { transaction in try ExpenseEdits.update(id, issuer: issuer, in: &transaction) { $0.manualRate = rate } }
      #expect(command != nil)
    }
    let changes = try await stores.main.read { transaction in try ExpenseChangeRecord.listing(in: transaction).entries.map(\.record.changes) }
    #expect(
      Set(changes) == [
        [.manualRate(from: nil, to: Self.manual("0.91"))], [.manualRate(from: Self.manual("0.91"), to: Self.manual("0.92"))],
        [.manualRate(from: Self.manual("0.92"), to: nil)],
      ])
    let expense = try await stores.main.read { transaction in try ExpenseRecord.read(ExpenseRecord.ref(id), in: transaction).entry?.record }
    #expect(expense?.manualRate == nil)
  }
}
