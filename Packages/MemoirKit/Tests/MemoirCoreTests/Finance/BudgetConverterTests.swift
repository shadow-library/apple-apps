import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Budget conversion", TestTimeLimit.quick)
struct BudgetConverterTests {
  private typealias F = BudgetFixture

  private static let eur = F.eur
  private static let usd = F.usd
  private static let jpy = F.jpy
  private static let gbp = F.gbp
  private static let kwd = F.currency("KWD")
  private static let aed = F.currency("AED")
  private static let clf = F.currency("CLF")
  private static let xau = F.currency("XAU")
  private static let day = F.date("2026-11-10")

  private static func rate(_ base: CurrencyCode, _ text: String, quote: CurrencyCode = eur, on date: LocalDate = day) -> FxRateRecord {
    FxRateRecord(base: base, quote: quote, date: date, rate: MoneyReadsFixture.decimal(text))
  }

  private static func expense(
    _ number: Int, _ amountMinor: Int64, _ currency: CurrencyCode, on date: LocalDate = day, rate: ExpenseRate? = nil, manual: ManualRate? = nil,
    budget: UUID? = nil
  ) throws -> ExpenseRecord {
    var expense = try FinanceFixture.expense(number, amountMinor: amountMinor, currency: currency, on: date, rate: rate)
    expense.manualRate = manual
    expense.budget = budget
    return expense
  }

  private static func inverted(_ amountMinor: Int64, _ home: CurrencyCode, to currency: CurrencyCode, at text: String) throws -> Int64 {
    let rate = try ExchangeRate(MoneyReadsFixture.decimal(text))
    return try BudgetConversion.convert(MoneyAmount(amountMinor: amountMinor, currency: home), to: currency, inverting: rate).amountMinor
  }

  private static func overflows(_ amountMinor: Int64, _ home: CurrencyCode, to currency: CurrencyCode, at text: String) throws -> Bool {
    do {
      _ = try inverted(amountMinor, home, to: currency, at: text)
      return false
    } catch FinanceError.overflow {
      return true
    }
  }

  @Test func shouldCountAnExpenseInItsBudgetsOwnCurrencyExactlyWithoutAnyRate() throws {
    let converter = BudgetConverter(home: Self.eur, rates: [])
    #expect(converter.amount(of: try Self.expense(1, 123_457, Self.jpy), in: Self.jpy) == .converted(123_457))
    #expect(converter.amount(of: try Self.expense(2, 9_007_199_254_740_993, Self.kwd), in: Self.kwd) == .converted(9_007_199_254_740_993))
    #expect(converter.amount(of: try Self.expense(3, -250, Self.eur), in: Self.eur) == .converted(-250))
    #expect(converter.amount(of: try Self.expense(4, 100, Self.xau), in: Self.xau) == .unconvertible(.unknownCurrency(Self.xau)))
    #expect(converter.amount(of: try Self.expense(5, 100, Self.eur), in: Self.xau) == .unconvertible(.unknownCurrency(Self.xau)))
  }

  @Test func shouldTakeTheHomeAmountAloneForABudgetInTheHomeCurrency() throws {
    let rates = [Self.rate(Self.usd, "0.9")]
    let converter = BudgetConverter(home: Self.eur, rates: rates)
    let dollars = try Self.expense(1, 1_000, Self.usd)
    #expect(converter.amount(of: dollars, in: Self.eur) == .converted(900))
    #expect(converter.amount(of: dollars, in: Self.eur).minor == HomeConverter(home: Self.eur, rates: rates).homeAmount(of: dollars).minor)
    #expect(converter.amount(of: try Self.expense(2, 1_000, Self.gbp), in: Self.eur) == .awaitingRate)
  }

  @Test func shouldConvertThroughHomeWithMixedExponentsRoundingEachStepHalfUp() throws {
    let euros = BudgetConverter(home: Self.eur, rates: [Self.rate(Self.jpy, "0.0061"), Self.rate(Self.kwd, "2.95")])
    #expect(euros.amount(of: try Self.expense(1, 1_000, Self.jpy), in: Self.kwd) == .converted(2_068), "¥1000 is €6.10, which is 2.06780 KWD")
    #expect(euros.amount(of: try Self.expense(2, 1_000, Self.eur), in: Self.jpy) == .converted(1_639), "€10 is ¥1639.34")
    #expect(euros.amount(of: try Self.expense(3, 1_234, Self.kwd), in: Self.jpy) == .converted(597), "1.234 KWD is €3.64, which is ¥596.72")

    let dinars = BudgetConverter(home: Self.kwd, rates: [Self.rate(Self.eur, "0.325", quote: Self.kwd), Self.rate(Self.jpy, "0.00205", quote: Self.kwd)])
    #expect(dinars.homeConverter.homeAmount(of: try Self.expense(4, 1_234, Self.eur)) == .converted(4_011), "€12.34 is 4.0105 KWD, a half rounded up")
    #expect(
      dinars.amount(of: try Self.expense(4, 1_234, Self.eur), in: Self.jpy) == .converted(1_957),
      "the rounded home amount 4.011 KWD is ¥1956.59; converting the unrounded 4.0105 would give ¥1956")
  }

  @Test func shouldRoundHalvesTowardPositiveInfinityWhenInverting() throws {
    #expect(try Self.inverted(4, Self.eur, to: Self.jpy, at: "0.1") == 0)
    #expect(try Self.inverted(5, Self.eur, to: Self.jpy, at: "0.1") == 1)
    #expect(try Self.inverted(15, Self.eur, to: Self.jpy, at: "0.1") == 2)
    #expect(try Self.inverted(25, Self.eur, to: Self.jpy, at: "0.1") == 3, "halves go up, never to even")
    #expect(try Self.inverted(-5, Self.eur, to: Self.jpy, at: "0.1") == 0)
    #expect(try Self.inverted(-6, Self.eur, to: Self.jpy, at: "0.1") == -1)
    #expect(try Self.inverted(-15, Self.eur, to: Self.jpy, at: "0.1") == -1)
    #expect(try Self.inverted(1, Self.eur, to: Self.kwd, at: "2") == 5)
    #expect(try Self.inverted(1, Self.eur, to: Self.kwd, at: "3") == 3)
    #expect(try Self.inverted(1, Self.eur, to: Self.kwd, at: "4") == 3)
    #expect(try Self.inverted(7, Self.jpy, to: Self.clf, at: "40000") == 2, "¥7 is 0.000175 CLF")
    #expect(try Self.inverted(250, Self.eur, to: Self.eur, at: "3") == 250)
  }

  @Test func shouldInvertExactlyWhereTheInverseTerminatesAndRoundTripTheHomeAmount() throws {
    #expect(try Self.inverted(1_000, Self.eur, to: Self.jpy, at: "0.008") == 1_250)
    let back = try HomeConversion.convert(MoneyAmount(amountMinor: 1_250, currency: Self.jpy), to: Self.eur, at: try ExchangeRate(MoneyReadsFixture.decimal("0.008")))
    #expect(back.amountMinor == 1_000)
    #expect(try Self.inverted(9_007_199_254_740_993, Self.eur, to: Self.usd, at: "1") == 9_007_199_254_740_993)
    #expect(try Self.inverted(9_007_199_254_740_993, Self.eur, to: Self.usd, at: "0.5") == 18_014_398_509_481_986)
    #expect(try Self.inverted(Int64.min, Self.eur, to: Self.usd, at: "1") == Int64.min)
  }

  @Test func shouldReportOverflowInsteadOfTruncating() throws {
    #expect(try Self.overflows(Int64.max, Self.eur, to: Self.kwd, at: "0.00000001"), "the quotient leaves Int64")
    #expect(try Self.overflows(Int64.max, Self.jpy, to: Self.clf, at: "0.000000000000000001"), "the scaled numerator leaves Int128")
    #expect(try Self.overflows(Int64.max, Self.eur, to: Self.usd, at: "0.5"))
    let converter = BudgetConverter(home: Self.eur, rates: [Self.rate(Self.kwd, "0.00000001")])
    #expect(converter.amount(of: try Self.expense(1, Int64.max, Self.eur), in: Self.kwd) == .unconvertible(.overflow))
  }

  @Test func shouldMatchHalfUpRoundingOfTheExactQuotientAcrossExponentsAmountsAndRates() throws {
    let currencies = [Self.jpy, Self.eur, Self.kwd, Self.clf]
    let amounts: [Int64] = [-9_007_199_254_740_993, -1_001, -1, 0, 1, 7, 999, 123_456_789, 9_007_199_254_740_993, Int64.max]
    let rates = ["0.0061", "1", "2.95", "0.00205", "150.25", "12.34567891", "0.000001", "123456789.123456789", "0.000000000000000003"]
    var checked = 0
    for home in currencies {
      for target in currencies where target != home {
        for text in rates {
          let rate = try ExchangeRate(MoneyReadsFixture.decimal(text))
          let shift = rate.scale + (try ISO4217.exponent(of: target)) - (try ISO4217.exponent(of: home))
          let ten = Int128(10)
          let scale = (0..<abs(shift)).reduce(Int128(1)) { value, _ in value * ten }
          let denominator = Int128(rate.significand) * (shift < 0 ? scale : 1)
          for amount in amounts {
            let (numerator, wide) = Int128(amount).multipliedReportingOverflow(by: shift >= 0 ? scale : 1)
            do {
              let result = Int128(try Self.inverted(amount, home, to: target, at: text))
              #expect(!wide)
              let twice = 2 * (numerator - result * denominator)
              #expect(-denominator <= twice && twice < denominator, "\(amount) \(home) to \(target) at \(text) gave \(result)")
              checked += 1
            } catch FinanceError.overflow {
              #expect(wide || (numerator / denominator).magnitude >= Int64.max.magnitude, "\(amount) \(home) to \(target) at \(text) fits")
            }
          }
        }
      }
    }
    #expect(checked > 600)
  }

  @Test func shouldAwaitEitherMissingRateOnTheExpensesOwnDateAndNeverANearerOne() throws {
    let before = F.date("2026-11-09")
    let converter = BudgetConverter(
      home: Self.eur, rates: [Self.rate(Self.usd, "0.9"), Self.rate(Self.jpy, "0.0061", on: before), Self.rate(Self.gbp, "1.2"), Self.rate(Self.aed, "0.25")])
    let unrated = try Self.expense(1, 1_000, Self.nok)
    #expect(converter.amount(of: unrated, in: Self.aed) == .awaitingRate, "the expense's own rate is missing")
    #expect(converter.missingRate(for: unrated, in: Self.aed) == nil, "the budget's rate is there; the expense's own is RateFiller's usual ask")
    let dollars = try Self.expense(2, 1_000, Self.usd)
    #expect(converter.amount(of: dollars, in: Self.jpy) == .awaitingRate, "the yen rate is a day early")
    #expect(converter.missingRate(for: dollars, in: Self.jpy) == CurrencyPair(base: Self.jpy, quote: Self.eur))
    #expect(converter.amount(of: try Self.expense(3, 1_000, Self.nok), in: Self.jpy) == .awaitingRate, "both are missing")
    #expect(converter.amount(of: try Self.expense(4, 1_000, Self.eur), in: Self.jpy) == .awaitingRate, "a home amount still needs the budget's rate")
    #expect(converter.amount(of: dollars, in: Self.aed) == .converted(3_600))
    #expect(converter.missingRate(for: dollars, in: Self.aed) == nil)
    #expect(converter.missingRate(for: dollars, in: Self.eur) == nil, "home needs no budget rate")
    #expect(converter.missingRate(for: dollars, in: Self.usd) == nil, "an expense in the budget's currency needs none")
    #expect(converter.missingRate(for: try Self.expense(5, 1_000, Self.xau), in: Self.jpy) == nil, "an unknown currency is never asked about")
    #expect(converter.missingRate(for: dollars, in: Self.xau) == nil)

    let foreign = BudgetConverter(home: Self.eur, rates: [Self.rate(Self.usd, "0.9"), Self.rate(Self.jpy, "0.0061", quote: Self.usd)])
    #expect(foreign.amount(of: try Self.expense(6, 1_000, Self.eur), in: Self.jpy) == .awaitingRate, "a rate quoted in another currency than home is not used")
    let broken = BudgetConverter(home: Self.eur, rates: [Self.rate(Self.usd, "0.9"), Self.rate(Self.jpy, "0")])
    #expect(broken.amount(of: dollars, in: Self.jpy) == .unconvertible(.rateNotPositive(MoneyReadsFixture.decimal("0"))))
  }

  @Test func shouldTakeTheOwnersRateIntoHomeBeforeTheLockedOrRecordedOne() throws {
    let locked = F.date("2026-11-08")
    let rates = [Self.rate(Self.usd, "0.9"), Self.rate(Self.jpy, "0.0064")]
    let converter = BudgetConverter(home: Self.eur, rates: rates)
    let lock = ExpenseRate(rate: MoneyReadsFixture.decimal("0.95"), date: Self.day, quote: Self.eur)
    var expense = try Self.expense(1, 10_000, Self.usd, rate: lock, manual: ManualRate(rate: MoneyReadsFixture.decimal("0.8"), quote: Self.eur))
    #expect(converter.amount(of: expense, in: Self.jpy) == .converted(12_500), "€80 at ¥156.25")
    expense.manualRate = ManualRate(rate: MoneyReadsFixture.decimal("120"), quote: Self.jpy)
    #expect(converter.amount(of: expense, in: Self.jpy) == .converted(14_063), "a rate into the budget's currency is not home's: €90 is ¥14062.5, up")
    expense.manualRate = nil
    #expect(converter.amount(of: expense, in: Self.jpy) == .converted(14_063), "the recorded rate of the locked day beats the locked rate")

    let lockedEarlier = try Self.expense(2, 10_000, Self.usd, rate: ExpenseRate(rate: MoneyReadsFixture.decimal("0.95"), date: locked, quote: Self.eur))
    #expect(converter.amount(of: lockedEarlier, in: Self.jpy) == .converted(14_844), "€95 from the lock, the yen rate of the expense's own date")
    let yenOnLockedDay = BudgetConverter(home: Self.eur, rates: [Self.rate(Self.jpy, "0.0064", on: locked)])
    #expect(yenOnLockedDay.amount(of: lockedEarlier, in: Self.jpy) == .awaitingRate, "the budget's rate is read for the expense's date, not the lock's")
  }

  @Test func shouldBuildTheLedgersBudgetConverterOnlyOnceTheVaultHasSettings() {
    let rates = [Self.rate(Self.jpy, "0.0061")]
    #expect(FinanceLedger(settings: nil, expenses: [], rates: rates, unreadable: 0).budgetConverter == nil)
    let ledger = FinanceLedger(settings: FinanceFixture.settings(home: Self.eur), expenses: [], rates: rates, unreadable: 0)
    #expect(ledger.budgetConverter?.home == Self.eur)
    #expect(ledger.budgetConverter?.recordedRate(of: Self.jpy, on: Self.day) == MoneyReadsFixture.decimal("0.0061"))
  }

  private static let nok = F.currency("NOK")
}

@Suite("Budget rate requests", TestTimeLimit.quick)
struct BudgetRateRequestTests {
  private typealias F = BudgetFixture

  private static let today = FinanceFixture.today
  private static let aed = F.currency("AED")

  private static func pair(_ base: CurrencyCode) -> CurrencyPair {
    CurrencyPair(base: base, quote: F.eur)
  }

  private static func expense(_ number: Int, _ amountMinor: Int64, _ currency: CurrencyCode, on date: String, budget: UUID? = nil) throws -> ExpenseRecord {
    var expense = try FinanceFixture.expense(number, amountMinor: amountMinor, currency: currency, on: F.date(date))
    expense.budget = budget
    return expense
  }

  private static func requests(in store: VaultStore) async throws -> RateRequests {
    try await store.read { transaction in try RateFiller.requests(in: transaction, today: today) }
  }

  @Test func shouldAskForATripsCurrencyOnTheDatesOfItsForeignExpensesOnce() async throws {
    let store = try await F.store()
    let trip = F.id(1)
    try await store.write { transaction in
      try BudgetEdits.create(F.trip("Tokyo", F.jpy, limitMinor: 100_000, from: "2026-11-18", through: "2026-11-28"), id: trip, today: Self.today, in: &transaction)
      try Self.expense(1, 1_000, F.usd, on: "2026-11-19").create(in: &transaction)
      try Self.expense(2, 500, F.eur, on: "2026-11-19").create(in: &transaction)
      try Self.expense(3, 1_000, F.jpy, on: "2026-11-20").create(in: &transaction)
      var typed = try Self.expense(4, 1_000, F.usd, on: "2026-11-20")
      typed.manualRate = ManualRate(rate: MoneyReadsFixture.decimal("0.9"), quote: F.eur)
      try typed.create(in: &transaction)
      try Self.expense(5, 1_000, F.usd, on: "2026-11-10").create(in: &transaction)
      try Self.expense(6, 700, F.eur, on: "2026-11-25").create(in: &transaction)
      try Self.expense(7, 300, F.eur, on: "2026-11-21").create(in: &transaction)
      try FxRateRecord(base: F.jpy, quote: F.eur, date: Self.today, rate: MoneyReadsFixture.decimal("0.0063")).create(in: &transaction)
    }
    let requests = try await Self.requests(in: store)
    #expect(
      requests.dates == [
        F.date("2026-11-10"): [Self.pair(F.usd)], F.date("2026-11-19"): [Self.pair(F.usd), Self.pair(F.jpy)], F.date("2026-11-20"): [Self.pair(F.jpy)],
      ], "the typed rate asks only for yen; the future expense and the day with a yen rate ask nothing")
    #expect(requests.dated.count == 4)
    #expect(!requests.pendingLocks)

    let client = ScriptedRatesClient([
      F.date("2026-11-10"): [Self.pair(F.usd): MoneyReadsFixture.decimal("0.9")],
      F.date("2026-11-19"): [Self.pair(F.usd): MoneyReadsFixture.decimal("0.92"), Self.pair(F.jpy): MoneyReadsFixture.decimal("0.0061")],
      F.date("2026-11-20"): [Self.pair(F.jpy): MoneyReadsFixture.decimal("0.0062")],
    ])
    let report = try await RateFiller(client: client).fill(store, today: Self.today)
    #expect(client.requests.map(\.date) == [F.date("2026-11-10"), F.date("2026-11-19"), F.date("2026-11-20")], "each date is asked once")
    #expect(report.recordedRates == 4)
    #expect(report.filledExpenses == 3, "the yen and the dollar expenses without a typed rate lock their own rate; a budget's rate locks nothing")
    #expect(try await Self.requests(in: store).isEmpty)

    let (ledger, assignments) = try await store.read { transaction in
      (try FinanceLedger.load(from: transaction), try BudgetAssignments.load(from: transaction))
    }
    let converter = try #require(ledger.budgetConverter)
    let tokyo = try #require(assignments.budgets.budget(trip))
    let amounts = Dictionary(uniqueKeysWithValues: assignments.expenses(assignedTo: trip).map { ($0.id, converter.amount(of: $0, in: tokyo)) })
    #expect(
      amounts == [
        FinanceFixture.expenseID(1): .converted(1_508), FinanceFixture.expenseID(2): .converted(820), FinanceFixture.expenseID(3): .converted(1_000),
        FinanceFixture.expenseID(4): .converted(1_452), FinanceFixture.expenseID(6): .awaitingRate, FinanceFixture.expenseID(7): .converted(476),
      ])
  }

  @Test func shouldAskForAResidentsMonthlyCurrencyOnlyForExpensesItHoldsInAnotherCurrency() async throws {
    let store = try await F.store()
    let dubai = F.id(2)
    try await store.write { transaction in
      try BudgetEdits.create(F.monthly("Dubai", Self.aed, limitMinor: 500_000), id: dubai, today: Self.today, in: &transaction)
      try Self.expense(1, 10_000, Self.aed, on: "2026-11-12").create(in: &transaction)
      try Self.expense(2, 1_000, F.usd, on: "2026-11-13", budget: dubai).create(in: &transaction)
      try Self.expense(3, 500, F.eur, on: "2026-11-14", budget: dubai).create(in: &transaction)
      try Self.expense(4, 1_000, F.usd, on: "2026-11-15").create(in: &transaction)
      var subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 16, anchorOn: F.date("2026-10-16"), amountMinor: 999, currency: F.gbp)
      subscription.budget = dubai
      try subscription.create(in: &transaction)
      var cycle = try Self.expense(5, 999, F.gbp, on: "2026-11-16")
      cycle.cycle = ExpenseCycleSeed(
        subscription: FinanceFixture.subscriptionID, amountMinor: 999, occurredOn: F.date("2026-11-16"), category: try MemoirStoreFixture.category("subs"))
      try cycle.create(in: &transaction)
      try Self.expense(6, 2_000, Self.aed, on: "2026-11-17").create(in: &transaction)
      try Self.expense(7, 2_000, F.eur, on: "2026-11-17", budget: dubai).create(in: &transaction)
      try FxRateRecord(base: Self.aed, quote: F.eur, date: F.date("2026-11-17"), rate: MoneyReadsFixture.decimal("0.25")).create(in: &transaction)
    }
    let requests = try await Self.requests(in: store)
    #expect(
      requests.dates == [
        F.date("2026-11-12"): [Self.pair(Self.aed)], F.date("2026-11-13"): [Self.pair(F.usd), Self.pair(Self.aed)], F.date("2026-11-14"): [Self.pair(Self.aed)],
        F.date("2026-11-15"): [Self.pair(F.usd)], F.date("2026-11-16"): [Self.pair(F.gbp), Self.pair(Self.aed)],
      ], "a dirham expense asks only its own rate; the cycle follows its subscription's budget; the active pound subscription asks nothing more")

    _ = try await store.write { transaction in try BudgetEdits.delete(dubai, in: &transaction) }
    #expect(
      try await Self.requests(in: store).dates == [
        F.date("2026-11-12"): [Self.pair(Self.aed)], F.date("2026-11-13"): [Self.pair(F.usd)], F.date("2026-11-15"): [Self.pair(F.usd)],
        F.date("2026-11-16"): [Self.pair(F.gbp)],
      ], "once the budget is gone its expenses count in Home and need no dirham rate")
  }

  @Test func shouldNeverAskTheOwnPairOfATypedRateExpenseCountedInItsOwnCurrency() async throws {
    let store = try await F.store()
    let trip = F.id(1)
    let dubai = F.id(2)
    try await store.write { transaction in
      try BudgetEdits.create(F.trip("Tokyo", F.jpy, limitMinor: 100_000, from: "2026-11-18", through: "2026-11-28"), id: trip, today: Self.today, in: &transaction)
      try BudgetEdits.create(F.monthly("Dubai", Self.aed, limitMinor: 500_000), id: dubai, today: Self.today, in: &transaction)
      var yen = try Self.expense(1, 5_000, F.jpy, on: "2026-11-19")
      yen.manualRate = ManualRate(rate: MoneyReadsFixture.decimal("0.0061"), quote: F.eur)
      try yen.create(in: &transaction)
      var dirhams = try Self.expense(2, 10_000, Self.aed, on: "2026-11-12")
      dirhams.manualRate = ManualRate(rate: MoneyReadsFixture.decimal("0.25"), quote: F.eur)
      try dirhams.create(in: &transaction)
    }
    let (ledger, assignments) = try await store.read { transaction in
      (try FinanceLedger.load(from: transaction), try BudgetAssignments.load(from: transaction))
    }
    #expect(assignments.assignments[FinanceFixture.expenseID(1)]?.budget == trip)
    #expect(assignments.assignments[FinanceFixture.expenseID(2)] == BudgetAssignment(budget: dubai, reason: .currency))
    let converter = try #require(ledger.budgetConverter)
    for expense in assignments.expenses {
      #expect(converter.missingRate(for: expense, in: expense.currency) == nil, "\(expense.currency) counts exactly in its own budget")
      #expect(converter.amount(of: expense, in: expense.currency) == .converted(expense.amountMinor))
    }
    let requests = try await Self.requests(in: store)
    #expect(requests.dates[F.date("2026-11-19")] == nil)
    #expect(requests.dates[F.date("2026-11-12")] == nil)
    #expect(requests.isEmpty)
  }

  @Test func shouldAskHomesOwnCurrencyWhenItDiffersFromTheAccountsDefault() async throws {
    let store = try await F.store()
    let ensured = try await store.write { transaction in
      try BudgetRecord(id: HomeBudget.id, currency: F.usd, period: .monthly, createdOn: F.date("2026-11-01")).create(in: &transaction)
      try Self.expense(1, 1_000, F.eur, on: "2026-11-12").create(in: &transaction)
      try Self.expense(2, 1_000, F.gbp, on: "2026-11-13").create(in: &transaction)
      try Self.expense(3, 1_000, F.usd, on: "2026-11-14").create(in: &transaction)
      try Self.expense(4, 1_000, F.usd, on: "2026-11-25").create(in: &transaction)
      return try HomeBudget.ensure(on: Self.today, in: &transaction)
    }
    guard case .currencyDiffers(let home, let account) = ensured else { throw HomeCurrencyFixtureError.notDiffering }
    #expect(home.currency == F.usd && account == F.eur)
    let requests = try await Self.requests(in: store)
    #expect(
      requests.dates == [
        F.date("2026-11-12"): [Self.pair(F.usd)], F.date("2026-11-13"): [Self.pair(F.gbp), Self.pair(F.usd)], F.date("2026-11-14"): [Self.pair(F.usd)],
      ], "every expense counted in Home asks Home's dollars against the default euro on its date, once; the future one waits")

    let client = ScriptedRatesClient([
      F.date("2026-11-12"): [Self.pair(F.usd): MoneyReadsFixture.decimal("0.9")],
      F.date("2026-11-13"): [Self.pair(F.gbp): MoneyReadsFixture.decimal("1.2"), Self.pair(F.usd): MoneyReadsFixture.decimal("0.8")],
      F.date("2026-11-14"): [Self.pair(F.usd): MoneyReadsFixture.decimal("0.95")],
    ])
    _ = try await RateFiller(client: client).fill(store, today: Self.today)
    #expect(try await Self.requests(in: store).isEmpty)
    let (ledger, assignments) = try await store.read { transaction in
      (try FinanceLedger.load(from: transaction), try BudgetAssignments.load(from: transaction))
    }
    let converter = try #require(ledger.budgetConverter)
    let live = try #require(assignments.budgets.home)
    let amounts = Dictionary(uniqueKeysWithValues: assignments.expenses(assignedTo: HomeBudget.id).map { ($0.id, converter.amount(of: $0, in: live)) })
    #expect(
      amounts == [
        FinanceFixture.expenseID(1): .converted(1_111), FinanceFixture.expenseID(2): .converted(1_500), FinanceFixture.expenseID(3): .converted(1_000),
        FinanceFixture.expenseID(4): .converted(1_000),
      ], "€10 at 0.9 is $11.11; £10 is €12 at 1.2, then $15 at 0.8; dollars count exactly")
  }

  private enum HomeCurrencyFixtureError: Error { case notDiffering }

  @Test func shouldLetABudgetsAskStandInForAnActiveSubscriptionsWeeklyRate() throws {
    let settings = FinanceFixture.settings(home: F.eur)
    let home = BudgetRecord(id: HomeBudget.id, currency: F.eur, period: .monthly, createdOn: F.date("2026-11-01"))
    let dubai = BudgetRecord(id: F.id(2), name: "Dubai", currency: Self.aed, limitMinor: 1, period: .monthly, createdOn: F.date("2026-11-01"))
    let budgets = Budgets(F.entries([(home, false), (dubai, false)]), settings: settings)
    let expense = try Self.expense(1, 1_000, F.eur, on: "2026-11-13", budget: dubai.id)
    let ledger = FinanceLedger(settings: settings, expenses: [expense], rates: [], unreadable: 0)
    let assignments = BudgetAssignments(budgets: budgets, expenses: [expense], subscriptions: [:])
    let subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 3, anchorOn: Self.today, amountMinor: 999, currency: Self.aed)
    #expect(RateFiller.requests(ledger, subscriptions: [subscription], assignments: assignments, today: Self.today).dates == [F.date("2026-11-13"): [Self.pair(Self.aed)]])
    #expect(
      RateFiller.requests(ledger, subscriptions: [subscription], today: Self.today).dates == [F.date("2026-11-20"): [Self.pair(Self.aed)]],
      "without budgets the subscription asks for yesterday as before")
  }
}
