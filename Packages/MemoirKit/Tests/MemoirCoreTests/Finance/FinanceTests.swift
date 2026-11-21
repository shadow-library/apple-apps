import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Finance", TestTimeLimit.quick)
struct FinanceTests {
  private static func code(_ text: String) throws -> CurrencyCode { try MemoirStoreFixture.currency(text) }
  private static func rate(_ text: String) throws -> ExchangeRate { try ExchangeRate(try MemoirStoreFixture.decimal(text)) }
  private static func date(_ text: String) throws -> LocalDate { try MemoirStoreFixture.date(text) }

  private static func convert(_ amount: Int64, _ from: String, _ to: String, _ rate: String) throws -> Int64 {
    try HomeConversion.convert(MoneyAmount(amountMinor: amount, currency: try code(from)), to: try code(to), at: try Self.rate(rate)).amountMinor
  }

  private static func refusal(_ body: () throws -> Void) -> FinanceError? {
    do {
      try body()
      return nil
    } catch let error as FinanceError {
      return error
    } catch {
      return .store("not a finance error: \(error)")
    }
  }

  @Test func shouldKnowTheExponentOfCurrenciesWithZeroThreeAndFourDecimals() throws {
    #expect(try ISO4217.exponent(of: try Self.code("JPY")) == 0)
    #expect(try ISO4217.exponent(of: try Self.code("KRW")) == 0)
    #expect(try ISO4217.exponent(of: try Self.code("KWD")) == 3)
    #expect(try ISO4217.exponent(of: try Self.code("TND")) == 3)
    #expect(try ISO4217.exponent(of: try Self.code("CLF")) == 4)
    #expect(try ISO4217.exponent(of: try Self.code("EUR")) == 2)
    #expect(Self.refusal { _ = try ISO4217.exponent(of: try! Self.code("XAU")) } == .unknownCurrency(try Self.code("XAU")))
    #expect(ISO4217.codes.count == ISO4217.exponents.count)
  }

  @Test func shouldScaleByTheDifferenceOfTheExponents() throws {
    #expect(try Self.convert(1_200, "JPY", "EUR", "0.0061") == 732)
    #expect(try Self.convert(999, "EUR", "JPY", "163.42") == 1_633)
    #expect(try Self.convert(1_000, "KWD", "EUR", "2.98") == 298)
    #expect(try Self.convert(1_005, "EUR", "KWD", "0.3355") == 3_372)
    #expect(try Self.convert(100, "JPY", "KWD", "0.00205") == 205)
    #expect(try Self.convert(12_345, "CLF", "USD", "40.5") == 5_000)
    #expect(try Self.convert(4_250, "USD", "EUR", "0.9213") == 3_916)
  }

  @Test func shouldRoundHalvesTowardPositiveInfinityAsJavaScriptDoes() throws {
    #expect(try Self.convert(5, "USD", "EUR", "0.5") == 3)
    #expect(try Self.convert(-5, "USD", "EUR", "0.5") == -2)
    #expect(try Self.convert(-7, "USD", "EUR", "0.5") == -3)
    #expect(try Self.convert(50, "USD", "EUR", "1.15") == 58)
    #expect(try Self.convert(0, "JPY", "EUR", "0.0061") == 0)
  }

  @Test func shouldConvertTheExtremesOfInt64OrReportOverflow() throws {
    #expect(try Self.convert(Int64.max, "USD", "EUR", "1") == Int64.max)
    #expect(try Self.convert(Int64.min, "USD", "EUR", "1") == Int64.min)
    #expect(try Self.convert(Int64.max, "USD", "EUR", "0.000000000000000001") == 9)
    #expect(Self.refusal { _ = try Self.convert(Int64.max, "USD", "EUR", "2") } == .overflow)
    #expect(Self.refusal { _ = try Self.convert(Int64.max, "JPY", "CLF", "999999999999999999") } == .overflow)
    #expect(Self.refusal { _ = try Self.convert(Int64.min, "USD", "EUR", "1.5") } == .overflow)
  }

  @Test func shouldNeedNoRateForTheHomeCurrencyButAnExponentForBoth() throws {
    #expect(try Self.convert(4_250, "EUR", "EUR", "7") == 4_250)
    #expect(Self.refusal { _ = try Self.convert(1, "XXX", "EUR", "1") } == .unknownCurrency(try Self.code("XXX")))
    #expect(Self.refusal { _ = try Self.convert(1, "EUR", "XXX", "1") } == .unknownCurrency(try Self.code("XXX")))
  }

  @Test func shouldReadARateExactlyFromItsDecimalText() throws {
    let rate = try Self.rate("12.34567891")
    #expect(rate.significand == 1_234_567_891)
    #expect(rate.scale == 8)
    #expect(rate.text.text == "12.34567891")
    #expect(try Self.rate("0.000000000000000001").scale == 18)
    #expect(try Self.rate("150").text.text == "150")
    let refusals: [(String, (DecimalText) -> FinanceError)] = [
      ("0", FinanceError.rateNotPositive), ("-1.5", FinanceError.rateNotPositive), ("1234567890123456789", FinanceError.rateOutOfRange),
      ("0.0000000000000000001", FinanceError.rateOutOfRange),
    ]
    for (text, expected) in refusals {
      let decimal = try MemoirStoreFixture.decimal(text)
      #expect(Self.refusal { _ = try ExchangeRate(decimal) } == expected(decimal), "\(text)")
    }
  }

  @Test func shouldRoundALongProviderRateToEightPlacesHalfUp() throws {
    let cases: [(String, String)] = [
      ("0.123456785", "0.12345679"), ("0.123456784999", "0.12345678"), ("9.999999995", "10"), ("1.10000000999", "1.10000001"), ("2", "2"),
      ("0.0856", "0.0856"), ("123.000000001", "123"),
    ]
    for (text, expected) in cases {
      #expect(try ExchangeRate.rounded(try MemoirStoreFixture.decimal(text)).text.text == expected, "\(text)")
    }
    let vanishing = try MemoirStoreFixture.decimal("0.000000004")
    #expect(Self.refusal { _ = try ExchangeRate.rounded(vanishing) } == .rateNotPositive(try MemoirStoreFixture.decimal("0")))
    #expect(Self.refusal { _ = try ExchangeRate.rounded(vanishing, toScale: 19) } == .rateOutOfRange(vanishing))
  }

  @Test func shouldAddMoneyOnlyInOneCurrencyAndWithinInt64() throws {
    let eur = try Self.code("EUR")
    let usd = try Self.code("USD")
    #expect(try MoneyAmount.sum([MoneyAmount(amountMinor: 1, currency: eur), MoneyAmount(amountMinor: -3, currency: eur)], in: eur).amountMinor == -2)
    #expect(Self.refusal { _ = try MoneyAmount(amountMinor: 1, currency: eur).adding(MoneyAmount(amountMinor: 1, currency: usd)) } == .currencyMismatch(eur, usd))
    #expect(Self.refusal { _ = try MoneyAmount(amountMinor: .max, currency: eur).adding(MoneyAmount(amountMinor: 1, currency: eur)) } == .overflow)
    #expect(Self.refusal { _ = try MoneyAmount(amountMinor: .min, currency: eur).subtracting(MoneyAmount(amountMinor: 1, currency: eur)) } == .overflow)
    #expect(Self.refusal { _ = try MoneyAmount(amountMinor: .min, currency: eur).negated() } == .overflow)
  }

  @Test func shouldRefuseACustomIntervalOfZeroOrLessAndAnUnknownFrequency() throws {
    #expect(Self.refusal { _ = try BillingTerms(frequency: .known(.custom), customIntervalDays: 0, billingDay: 1) } == .customIntervalNotPositive(0))
    #expect(Self.refusal { _ = try BillingTerms(frequency: .known(.custom), customIntervalDays: -3, billingDay: 1) } == .customIntervalNotPositive(-3))
    #expect(Self.refusal { _ = try BillingTerms(frequency: .unknown("fortnightly"), customIntervalDays: nil, billingDay: 1) } == .unknownFrequency("fortnightly"))
    #expect(Self.refusal { _ = try BillingTerms(frequency: .known(.monthly), customIntervalDays: nil, billingDay: 32) } == .billingDayOutOfRange(32))
    #expect(try BillingTerms(frequency: .known(.weekly), customIntervalDays: 0, billingDay: 1).frequency == .weekly)
    let terms = try BillingTerms(frequency: .known(.weekly), customIntervalDays: nil, billingDay: 1)
    #expect(Self.refusal { _ = try terms.monthlyEquivalentMinor(of: .max) } == .overflow)
    #expect(Self.refusal { _ = try terms.nextDueDate(after: .latest) } == .dateOutOfRange)
  }

  @Test func shouldLetTheLatestConfirmedCycleWinInAnyOrder() throws {
    let subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 31, anchorOn: try Self.date("2026-01-31"), amountMinor: 999, currency: try Self.code("EUR"))
    let other = CycleConfirmation(subscription: MemoirStoreFixture.quest, billingDate: try Self.date("2027-01-31"))
    let dates = try ["2026-01-31", "2026-03-31", "2026-02-28"].map { CycleConfirmation(subscription: subscription.id, billingDate: try Self.date($0)) }
    for order in [dates, dates.reversed(), [dates[1], dates[0], dates[2]]] {
      let schedule = try SubscriptionSchedule(subscription: subscription, confirmations: order + [other])
      #expect(schedule.lastConfirmed == (try Self.date("2026-03-31")))
      #expect(schedule.nextDue == (try Self.date("2026-04-30")))
    }
    let fresh = try SubscriptionSchedule(subscription: subscription, confirmations: [])
    #expect(fresh.nextDue == subscription.anchorOn)
    #expect(fresh.lastConfirmed == nil)
    var moved = subscription
    moved.anchorOn = try Self.date("2026-06-15")
    let afterMove = try SubscriptionSchedule(subscription: moved, confirmations: dates)
    #expect(afterMove.nextDue == moved.anchorOn)
    #expect(afterMove.lastConfirmed == (try Self.date("2026-03-31")))
    var broken = subscription
    broken.frequency = .known(.custom)
    broken.customIntervalDays = 0
    #expect(Self.refusal { _ = try SubscriptionSchedule(subscription: broken, confirmations: dates) } == .customIntervalNotPositive(0))
  }

  @Test func shouldClearTheBudgetOnACurrencyChangeAndIgnoreOneInAnotherCurrency() throws {
    let eur = try Self.code("EUR")
    let nok = try Self.code("NOK")
    var settings = FinanceFixture.settings(home: eur, budgetMinor: 160_000)
    try settings.changeDefaultCurrency(to: eur)
    #expect(settings.effectiveMonthlyBudget?.amountMinor == 160_000)
    try settings.changeDefaultCurrency(to: nok)
    #expect(settings.monthlyBudget == nil)
    #expect(settings.enabledCurrencies == [nok, eur])
    #expect(Self.refusal { try settings.changeDefaultCurrency(to: try! Self.code("XAU")) } == .unknownCurrency(try Self.code("XAU")))
    #expect(Self.refusal { try settings.setMonthlyBudget(amountMinor: -1) } == .negativeBudget(-1))
    try settings.setMonthlyBudget(amountMinor: 0)
    #expect(settings.effectiveMonthlyBudget == MoneyAmount(amountMinor: 0, currency: nok))
    settings.monthlyBudget = MoneyAmount(amountMinor: 5_000, currency: eur)
    #expect(settings.effectiveMonthlyBudget == nil)
    #expect(try BudgetStanding(settings: settings, expenses: [], converter: HomeConverter(home: nok, rates: []), today: FinanceFixture.today) == nil)
  }

  @Test func shouldCountUnconvertedExpensesApartAndConvertThroughTheNewHomeAfterAChange() throws {
    let eur = try Self.code("EUR")
    let nok = try Self.code("NOK")
    let jpy = try Self.code("JPY")
    let day = try Self.date("2026-11-10")
    let lockedForNok = ExpenseRate(rate: try MemoirStoreFixture.decimal("0.068"), date: day, quote: nok)
    let expenses = [
      try FinanceFixture.expense(1, amountMinor: 1_200, currency: jpy, on: day, rate: lockedForNok),
      try FinanceFixture.expense(2, amountMinor: 5_000, currency: jpy, on: day),
      try FinanceFixture.expense(3, amountMinor: 250, currency: eur, on: day),
      try FinanceFixture.expense(4, amountMinor: 100, currency: try Self.code("XXX"), on: day),
      try FinanceFixture.expense(5, amountMinor: 999, currency: eur, on: try Self.date("2026-10-31")),
    ]
    let fresh = try MonthSpend(monthOf: FinanceFixture.today, expenses: expenses, converter: HomeConverter(home: eur, rates: []))
    #expect(fresh.spentMinor == 250)
    #expect(fresh.awaitingRate == 2)
    #expect(fresh.unconvertible == 1)
    let rate = FxRateRecord(base: jpy, quote: eur, date: day, rate: try MemoirStoreFixture.decimal("0.0061"))
    let filled = try MonthSpend(monthOf: FinanceFixture.today, expenses: expenses, converter: HomeConverter(home: eur, rates: [rate]))
    #expect(filled.spentMinor == 250 + 732 + 3_050)
    #expect(filled.awaitingRate == 0)
    #expect(filled.first == (try Self.date("2026-11-01")))
    #expect(filled.last == (try Self.date("2026-11-30")))
    let inNok = try MonthSpend(monthOf: FinanceFixture.today, expenses: expenses, converter: HomeConverter(home: nok, rates: [rate]))
    #expect(inNok.spentMinor == 8_160)
    #expect(inNok.awaitingRate == 2)
  }

  @Test func shouldCaptureARecordedRateWhenAnExpenseIsWritten() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let eur = try Self.code("EUR")
    let usd = try Self.code("USD")
    let day = try Self.date("2026-11-10")
    try await store.write { transaction in
      try FinanceFixture.settings(home: eur).create(in: &transaction)
      try FxRateRecord(base: usd, quote: eur, date: day, rate: try MemoirStoreFixture.decimal("0.9213")).create(in: &transaction)
    }
    let written = try await store.write { transaction in
      [
        try FinanceFixture.expense(1, amountMinor: 4_250, currency: usd, on: day).createCapturingRate(in: &transaction),
        try FinanceFixture.expense(2, amountMinor: 4_250, currency: usd, on: try Self.date("2026-11-11")).createCapturingRate(in: &transaction),
        try FinanceFixture.expense(3, amountMinor: 4_250, currency: eur, on: day).createCapturingRate(in: &transaction),
      ]
    }
    #expect(written.map { $0.rate?.rate.text } == ["0.9213", nil, nil])
    let ledger = try await FinanceFixture.ledger(in: store)
    #expect(ledger.expenses.map(\.rate) == written.map(\.rate))
    #expect(try ledger.budgetStanding(today: day) == nil)
  }

  @Test func shouldAskOnlyForPairsOnEachExpensesOwnDateAndRecordWhatComesBack() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let eur = try Self.code("EUR")
    let usd = try Self.code("USD")
    let gbp = try Self.code("GBP")
    let first = try Self.date("2026-11-01")
    let second = try Self.date("2026-11-02")
    let third = try Self.date("2026-11-03")
    try await store.write { transaction in
      try FinanceFixture.settings(home: eur, budgetMinor: 100_000).create(in: &transaction)
      try FinanceFixture.expense(1, amountMinor: 1_000, currency: usd, on: first).create(in: &transaction)
      try FinanceFixture.expense(2, amountMinor: 2_000, currency: usd, on: first).create(in: &transaction)
      try FinanceFixture.expense(3, amountMinor: 3_000, currency: gbp, on: second).create(in: &transaction)
      try FinanceFixture.expense(4, amountMinor: 4_000, currency: usd, on: third).create(in: &transaction)
      try FinanceFixture.expense(5, amountMinor: 5_000, currency: usd, on: try Self.date("2026-11-22")).create(in: &transaction)
      try FinanceFixture.expense(6, amountMinor: 6_000, currency: eur, on: first).create(in: &transaction)
    }
    let usdEur = CurrencyPair(base: usd, quote: eur)
    let gbpEur = CurrencyPair(base: gbp, quote: eur)
    let client = ScriptedRatesClient(
      [first: [usdEur: try MemoirStoreFixture.decimal("0.912345678")], second: [:], third: [usdEur: try MemoirStoreFixture.decimal("0.93")]], failing: [third])
    let report = try await RateFiller(client: client).fill(store, today: FinanceFixture.today)
    #expect(Set(client.requests.map(\.date)) == [first, second, third])
    #expect(client.requests.allSatisfy { request in request.date == second ? request.pairs == [gbpEur] : request.pairs == [usdEur] })
    #expect(report.recordedRates == 1)
    #expect(report.filledExpenses == 2)
    #expect(report.unavailable == [second: [gbpEur]])
    #expect(report.failedDates == [third])
    let ledger = try await FinanceFixture.ledger(in: store)
    #expect(ledger.rates == [FxRateRecord(base: usd, quote: eur, date: first, rate: try MemoirStoreFixture.decimal("0.91234568"))])
    #expect(ledger.expenses.filter { $0.rate != nil }.map(\.id) == [FinanceFixture.expenseID(1), FinanceFixture.expenseID(2)])
    let standing = try #require(try ledger.budgetStanding(today: FinanceFixture.today))
    #expect(standing.spend.spentMinor == 912 + 1_825 + 6_000)
    #expect(standing.spend.awaitingRate == 3)
    #expect(standing.daysLeft == 10)

    let quiet = ScriptedRatesClient([:])
    let again = try await RateFiller(client: quiet, maximumDates: 1).fill(store, today: FinanceFixture.today)
    #expect(quiet.requests.map(\.date) == [third])
    #expect(again.deferredDates == [second])
  }

  @Test func shouldLockAnExpenseFromARateAnotherDeviceRecordedWithoutAsking() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let eur = try Self.code("EUR")
    let usd = try Self.code("USD")
    let day = try Self.date("2026-11-01")
    try await store.write { transaction in
      try FinanceFixture.settings(home: eur).create(in: &transaction)
      try FinanceFixture.expense(1, amountMinor: 1_000, currency: usd, on: day).create(in: &transaction)
      try FxRateRecord(base: usd, quote: eur, date: day, rate: try MemoirStoreFixture.decimal("0.9")).create(in: &transaction)
    }
    let client = ScriptedRatesClient([:])
    let report = try await RateFiller(client: client).fill(store, today: FinanceFixture.today)
    #expect(client.requests.isEmpty)
    #expect(report.filledExpenses == 1)
    #expect(try await FinanceFixture.ledger(in: store).expenses.first?.rate == ExpenseRate(rate: try MemoirStoreFixture.decimal("0.9"), date: day, quote: eur))
    let idle = try await RateFiller(client: client).fill(store, today: FinanceFixture.today)
    #expect(idle == RateFillReport())
  }

  @Test func shouldConfirmACycleOnceAndRefuseAMissingOrRemovedSubscription() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let eur = try Self.code("EUR")
    let usd = try Self.code("USD")
    let anchor = try Self.date("2026-01-15")
    let subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 15, anchorOn: anchor, amountMinor: 1_999, currency: usd)
    let confirmation = CycleConfirmation(subscription: subscription.id, billingDate: anchor)
    try await store.write { transaction in
      try FinanceFixture.settings(home: eur).create(in: &transaction)
      try subscription.create(in: &transaction)
      try FxRateRecord(base: usd, quote: eur, date: anchor, rate: try MemoirStoreFixture.decimal("0.9213")).create(in: &transaction)
    }
    let first = try await store.write { transaction in try SubscriptionCycles.confirm(confirmation, loggedAtMillis: 10, in: &transaction) }
    let expense = try #require(first)
    #expect(expense.id == derivedID("com.shadow.library.memoircore.subscription-cycle-expense", "\(subscription.id.lowercasedString)|2026-01-15"))
    #expect(expense.amountMinor == 1_999 && expense.currency == usd && expense.occurredOn == anchor && expense.note == "Plan")
    #expect(expense.rate == ExpenseRate(rate: try MemoirStoreFixture.decimal("0.9213"), date: anchor, quote: eur))
    _ = try await store.write { transaction in try ExpenseRecord.remove(expense.ref, in: &transaction) }
    let second = try await store.write { transaction in try SubscriptionCycles.confirm(confirmation, loggedAtMillis: 11, in: &transaction) }
    #expect(second == nil)
    #expect(try await FinanceFixture.ledger(in: store).expenses.isEmpty)

    let unknown = CycleConfirmation(subscription: MemoirStoreFixture.quest, billingDate: anchor)
    #expect(try await Self.refusal(confirming: unknown, in: store) == .subscriptionAbsent(MemoirStoreFixture.quest))
    _ = try await store.write { transaction in try SubscriptionRecord.remove(subscription.ref, in: &transaction) }
    let next = CycleConfirmation(subscription: subscription.id, billingDate: try Self.date("2026-02-15"))
    #expect(try await Self.refusal(confirming: next, in: store) == .subscriptionAbsent(subscription.id))
  }

  private static func refusal(confirming confirmation: CycleConfirmation, in store: VaultStore) async throws -> FinanceError? {
    try await store.write { transaction -> FinanceError? in
      do throws(FinanceError) {
        try SubscriptionCycles.confirm(confirmation, loggedAtMillis: 1, in: &transaction)
        return nil
      } catch {
        return error
      }
    }
  }
}
