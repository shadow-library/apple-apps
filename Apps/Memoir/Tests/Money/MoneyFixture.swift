import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

/// In-memory stores on a test clock at noon UTC of `TestClock.day0` (a Monday), with a euro account unless asked otherwise.
@MainActor
enum MoneyFixture {
  nonisolated static let euro = CurrencyCode("EUR")!
  nonisolated static let krone = CurrencyCode("NOK")!
  nonisolated static let yen = CurrencyCode("JPY")!
  nonisolated static let dinar = CurrencyCode("KWD")!
  nonisolated static let food = CategoryKey("food")!
  nonisolated static let transport = CategoryKey("transport")!
  nonisolated static let subs = CategoryKey("subs")!
  nonisolated static let uncategorised = CategoryKey("uncat")!
  nonisolated static let english = Locale(identifier: "en_US")
  nonisolated static let german = Locale(identifier: "de_DE")

  static func context(home: CurrencyCode? = euro, enabled: [CurrencyCode] = [euro, krone], budgetMinor: Int64? = nil) async throws -> MemoirScreenContext {
    let clock = TestClock(day: 0, minute: 720)
    let context = try MemoirScreenContext.inMemory(clock: clock.memoir(deviceZone: TestClock.utc))
    guard let home else { return context }
    let settings = AccountSettingsRecord(
      defaultCurrency: home, enabledCurrencies: enabled, monthlyBudget: budgetMinor.map { MoneyAmount(amountMinor: $0, currency: home) })
    try await context.writer.write { _, transaction in _ = try settings.create(in: &transaction) }
    return context
  }

  static func options(_ context: MemoirScreenContext) async throws -> MoneyOptions {
    try await MoneyOptions.load(context)
  }

  @discardableResult
  static func expense(
    _ context: MemoirScreenContext, _ amountMinor: Int64, _ currency: CurrencyCode = euro, on date: LocalDate = TestClock.day0, category: CategoryKey = food,
    note: String? = nil, merchant: String? = nil
  ) async throws -> ExpenseRecord {
    let expense = ExpenseRecord(
      id: UUID.v7(at: context.clock.now()), amountMinor: amountMinor, currency: currency, occurredOn: date, category: category, merchant: merchant, note: note,
      loggedAtMillis: MemoirClock.millis(context.clock.now()))
    return try await context.writer.write { issuer, transaction in try ExpenseEdits.create(expense, issuer: issuer, in: &transaction).expense }
  }

  static func bodies(_ context: MemoirScreenContext) async throws -> [MemoirCommandBody] {
    try await context.stores.commands().map { command in
      try MemoirCommandBody(type: command.payload.type, payload: command.payload.members, occurrence: command.occurrence)
    }
  }

  /// Every expense entry, removed ones included.
  static func expenseEntries(_ context: MemoirScreenContext) async throws -> [MemoirEntry<ExpenseRecord>] {
    try await context.stores.main.read { transaction in try ExpenseRecord.listing(in: transaction).entries }
  }

  static func changeRecords(_ context: MemoirScreenContext) async throws -> [ExpenseChangeRecord] {
    try await context.stores.main.read { transaction in try ExpenseChangeRecord.listing(in: transaction).entries.map(\.record) }
  }

  static func subscriptions(_ context: MemoirScreenContext) async throws -> [MemoirEntry<SubscriptionRecord>] {
    try await context.stores.main.read { transaction in try SubscriptionRecord.listing(in: transaction).entries }
  }

  static func loaded<Value>(_ feed: MoneyFeed<Value>, _ what: String, where condition: @escaping (Value) -> Bool = { _ in true }) async throws -> Value {
    try await TestClock.until(what) { feed.state.value.map(condition) ?? false }
    return try #require(feed.state.value)
  }
}
