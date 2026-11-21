import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Finance vectors", TestTimeLimit.standard)
struct FinanceVectorTests {
  @Test func shouldConvertEveryCaptureVectorAsTheReferenceOrTheExactModel() async throws {
    try await FinanceVectors.check("conversion.json", "captureFx") { input in
      let currency = try input["currency"].currency
      let home = try input["home"].currency
      let expense = ExpenseRecord(
        id: FinanceFixture.expenseID(1), amountMinor: Int64(try input["amountMinor"].int), currency: currency, occurredOn: FinanceFixture.today,
        category: try MemoirStoreFixture.category("food"), rate: try input["rate"].optionalDecimal.map { ExpenseRate(rate: $0, date: FinanceFixture.today, quote: home) },
        loggedAtMillis: 1)
      switch HomeConverter(home: home, rates: []).homeAmount(of: expense) {
      case .converted(let minor): return .minor(minor)
      case .awaitingRate: return .null
      case .unconvertible(let error): throw error
      }
    }
  }

  @Test func shouldFillRatesForEachExpensesOwnDateAsTheReferenceSweepDoes() async throws {
    try await FinanceVectors.check("conversion.json", "reconcile") { input in
      let home = try input["home"].currency
      let store = try MemoirStore.openInMemory(.main)
      let expenses = try input["expenses"].array.enumerated().map { index, item in
        try FinanceFixture.expense(index, amountMinor: Int64(try item["amountMinor"].int), currency: try item["currency"].currency, on: try item["occurredOn"].localDate)
      }
      let labels = Dictionary(uniqueKeysWithValues: try input["expenses"].array.enumerated().map { index, item in (FinanceFixture.expenseID(index), try item["id"].string) })
      try await store.write { transaction in
        try FinanceFixture.settings(home: home).create(in: &transaction)
        for expense in expenses { try expense.create(in: &transaction) }
      }
      guard case .object(let provider) = try input["provider"] else { throw FixtureError.malformed("provider is not an object") }
      var table = [LocalDate: [CurrencyPair: DecimalText]]()
      for (date, quotes) in provider {
        guard case .object(let rates) = quotes else { throw FixtureError.malformed("\(quotes) is not a rate table") }
        let day = try FixtureValue.string(date).localDate
        for (code, rate) in rates { table[day, default: [:]][CurrencyPair(base: try FixtureValue.string(code).currency, quote: home)] = try rate.decimal }
      }
      _ = try await RateFiller(client: ScriptedRatesClient(table)).fill(store, today: FinanceFixture.today)
      let ledger = try await FinanceFixture.ledger(in: store)
      let converter = try #require(ledger.converter)
      var resolved = [FixtureValue]()
      for expense in ledger.expenses.sorted(by: { $0.id.lowercasedString < $1.id.lowercasedString }) {
        guard let rate = expense.rate else { continue }
        resolved.append(
          .object([
            "id": .string(labels[expense.id] ?? "?"), "fxRate": .string(rate.rate.text), "homeAmountMinor": .minor(converter.homeAmount(of: expense).minor),
            "fxRateDate": .string(rate.date.isoString),
          ]))
      }
      return .array(resolved)
    }
  }

  @Test func shouldComputeTheMonthlyEquivalentAsTheReferenceAndRefuseANonPositiveInterval() async throws {
    try await FinanceVectors.check("monthly-equivalent.json", "monthlyEquivalentMinor") { input in
      let terms = try BillingTerms(
        frequency: StoredChoice(rawValue: try input["frequency"].string), customIntervalDays: try input["customIntervalDays"].optionalInt, billingDay: 1)
      return .minor(try terms.monthlyEquivalentMinor(of: Int64(try input["amountMinor"].int)))
    }
  }

  @Test func shouldStandAgainstTheMonthlyBudgetAsTheReference() async throws {
    try await FinanceVectors.check("budget.json", "budgetStanding") { input in
      let home = try input["home"].currency
      let today = try input["today"].localDate
      let settings = FinanceFixture.settings(home: home, budgetMinor: try input["budgetMinor"].optionalInt.map(Int64.init))
      let expenses = try input["expenses"].array.enumerated().map { index, item in
        let date = try item["occurredOn"].localDate
        let rate = try item["rate"].optionalDecimal.map { ExpenseRate(rate: $0, date: date, quote: home) }
        return try FinanceFixture.expense(index, amountMinor: Int64(try item["amountMinor"].int), currency: try item["currency"].currency, on: date, rate: rate)
      }
      guard let standing = try BudgetStanding(settings: settings, expenses: expenses, converter: HomeConverter(home: home, rates: []), today: today) else {
        return .object(["kind": .string("unset")])
      }
      return .object([
        "kind": .string("set"), "budgetMinor": .minor(standing.budget.amountMinor), "spentMinor": .minor(standing.spend.spentMinor),
        "leftMinor": .minor(standing.leftMinor), "daysLeft": .int(standing.daysLeft),
      ])
    }
  }

  @Test func shouldClearTheBudgetWhenTheDefaultCurrencyChangesAsOnboardingDoes() async throws {
    try await FinanceVectors.check("budget.json", "onboard") { input in
      let before = try input["defaultCurrency"].currency
      var settings = FinanceFixture.settings(home: before, budgetMinor: try input["budgetMinor"].optionalInt.map(Int64.init))
      settings.enabledCurrencies = [try FixtureValue.string("USD").currency]
      try settings.changeDefaultCurrency(to: try input["onboardCurrency"].currency)
      return .object([
        "defaultCurrency": .string(settings.defaultCurrency.code), "enabledCurrencies": .array(settings.enabledCurrencies.map { .string($0.code) }),
        "monthlyBudgetMinor": .minor(settings.effectiveMonthlyBudget?.amountMinor),
      ])
    }
  }

  @Test func shouldDeriveEachConfirmedCycleAndWriteItsExpenseOnce() async throws {
    try await FinanceVectors.check("cycle.json", "confirmSubscriptionCycle") { input in
      let home = try input["home"].currency
      let shape = try input["subscription"]
      let frequency = try shape["frequency"].key(SubscriptionFrequency.self)
      let currency = try shape["currency"].currency
      let subscription = try FinanceFixture.subscription(
        frequency: frequency, billingDay: try shape["billingDay"].int, customIntervalDays: try shape["customIntervalDays"].optionalInt,
        anchorOn: try shape["nextDueDate"].localDate, amountMinor: Int64(try shape["amountMinor"].int), currency: currency)
      let confirms = try input["confirms"].array.map { try $0.localDate }
      let rate = try input["rate"].optionalDecimal
      let store = try MemoirStore.openInMemory(.main)
      try await store.write { transaction in
        try FinanceFixture.settings(home: home).create(in: &transaction)
        try subscription.create(in: &transaction)
        guard let rate else { return }
        for date in Set(confirms) { try FxRateRecord(base: currency, quote: home, date: date, rate: rate).create(in: &transaction) }
      }
      var confirmed = [CycleConfirmation]()
      var steps = [FixtureValue]()
      for (index, date) in confirms.enumerated() {
        let confirmation = CycleConfirmation(subscription: subscription.id, billingDate: date)
        let written = try await store.write { transaction in
          try SubscriptionCycles.confirm(confirmation, loggedAtMillis: Int64(index), in: &transaction)
        }
        confirmed.append(confirmation)
        let schedule = try SubscriptionSchedule(subscription: subscription, confirmations: confirmed)
        let ledger = try await FinanceFixture.ledger(in: store)
        let expense = try #require(ledger.expenses.first { $0.id == SubscriptionCycles.expenseID(for: confirmation) })
        let home: FixtureValue = currency == home ? .null : .minor(try #require(ledger.converter).homeAmount(of: expense).minor)
        steps.append(
          .object([
            "inserted": .bool(written != nil), "nextDueDate": .string(schedule.nextDue.isoString), "lastConfirmedDate": .string(schedule.lastConfirmed?.isoString ?? ""),
            "homeAmountMinor": home,
          ]))
      }
      return .array(steps)
    }
  }

  @Test func shouldCoverEveryCurrencyTheReferenceAcceptsWithItsExponent() throws {
    let reference = try FinanceVectors.load(CurrencyFixture.self, "currencies.json")
    #expect(reference.codes.count == 19)
    for code in reference.codes {
      let currency = try FixtureValue.string(code).currency
      #expect(try ISO4217.exponent(of: currency) == reference.exponents[code], "\(code)")
    }
  }
}
