import Foundation
import MemoirCore
import ShadowCore
import ShadowStore
import Synchronization

enum FinanceFixture {
  static let today = LocalDate(year: 2026, month: 11, day: 21) ?? .earliest

  static func expenseID(_ number: Int) -> UUID {
    MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-%012x", 0xE000 + number))
  }

  static let subscriptionID = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000d001")

  static func settings(home: CurrencyCode, budgetMinor: Int64? = nil) -> AccountSettingsRecord {
    AccountSettingsRecord(defaultCurrency: home, enabledCurrencies: [home], monthlyBudget: budgetMinor.map { MoneyAmount(amountMinor: $0, currency: home) })
  }

  static func expense(
    _ number: Int, amountMinor: Int64, currency: CurrencyCode, on date: LocalDate, rate: ExpenseRate? = nil, loggedAtMillis: Int64 = 1_763_600_000_000
  ) throws -> ExpenseRecord {
    ExpenseRecord(
      id: expenseID(number), amountMinor: amountMinor, currency: currency, occurredOn: date, category: try MemoirStoreFixture.category("food"), rate: rate,
      loggedAtMillis: loggedAtMillis)
  }

  static func subscription(
    frequency: SubscriptionFrequency, billingDay: Int, customIntervalDays: Int? = nil, anchorOn: LocalDate, amountMinor: Int64, currency: CurrencyCode
  ) throws -> SubscriptionRecord {
    SubscriptionRecord(
      id: subscriptionID, name: "Gym", note: "Plan", amountMinor: amountMinor, currency: currency, frequency: .known(frequency), customIntervalDays: customIntervalDays,
      billingDay: billingDay, anchorOn: anchorOn, category: try MemoirStoreFixture.category("subs"))
  }

  static func ledger(in store: VaultStore) async throws -> FinanceLedger {
    try await store.read { transaction in try FinanceLedger.load(from: transaction) }
  }
}

/// Answers from a fixed table and records every request, so a test can check that only pairs and dates leave the device.
final class ScriptedRatesClient: RatesClient {
  private let table: [LocalDate: [CurrencyPair: DecimalText]]
  private let failing: Set<LocalDate>
  private let log = Mutex([(pairs: Set<CurrencyPair>, date: LocalDate)]())

  init(_ table: [LocalDate: [CurrencyPair: DecimalText]], failing: Set<LocalDate> = []) {
    self.table = table
    self.failing = failing
  }

  var requests: [(pairs: Set<CurrencyPair>, date: LocalDate)] { log.withLock { $0 } }

  func rates(for pairs: Set<CurrencyPair>, on date: LocalDate) async throws(RatesClientError) -> [CurrencyPair: DecimalText] {
    log.withLock { $0.append((pairs, date)) }
    if failing.contains(date) { throw .unavailable("scripted failure") }
    return (table[date] ?? [:]).filter { pairs.contains($0.key) }
  }
}
