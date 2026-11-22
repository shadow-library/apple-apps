import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

enum MoneyReadsFixture {
  static func date(_ text: String) -> LocalDate {
    guard let date = LocalDate(isoString: text) else { preconditionFailure("\(text) is a date") }
    return date
  }

  static func decimal(_ text: String) -> DecimalText {
    guard let value = DecimalText(text) else { preconditionFailure("\(text) is a canonical decimal") }
    return value
  }

  static func currency(_ text: String) -> CurrencyCode {
    guard let code = CurrencyCode(text) else { preconditionFailure("\(text) is a currency code") }
    return code
  }

  static func category(_ text: String) -> CategoryKey {
    guard let key = CategoryKey(text) else { preconditionFailure("\(text) is a category key") }
    return key
  }

  static func id(_ number: Int) -> UUID {
    MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-%012x", 0xA000 + number))
  }

  /// Midday UTC of `date`, in milliseconds.
  static func millis(_ date: LocalDate, hour: Int = 12) -> Int64 {
    Int64(date.daysSinceEpoch) * 86_400_000 + Int64(hour) * 3_600_000
  }

  static func wallClock(_ date: LocalDate, hour: Int = 12) -> @Sendable () -> Date {
    let instant = Date(timeIntervalSince1970: TimeInterval(millis(date, hour: hour)) / 1000)
    return { instant }
  }

  static func issuer(on date: LocalDate, hour: Int = 12) -> CommandIssuer {
    guard let utc = TimeZone(identifier: "UTC") else { preconditionFailure("UTC exists") }
    return CommandIssuer(clock: IssueClock(timeZone: utc), wallClock: wallClock(date, hour: hour))
  }

  static func stamp(_ date: LocalDate, hour: Int = 12) -> IssueStamp {
    IssueStamp(instantMillis: millis(date, hour: hour), utcOffsetMinutes: 0, issuedOn: date)
  }

  static func command(_ number: Int, _ body: MemoirCommandBody, on date: LocalDate, hour: Int = 12) throws -> MemoirCommand {
    let stamp = stamp(date, hour: hour)
    return try MemoirCommand(
      id: MemoirStoreFixture.commandID(number), body: body, instantMillis: stamp.instantMillis, utcOffsetMinutes: 0, issuedOn: date, rulesetVersion: 1)
  }

  static func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
    try await store.write { transaction in try body(&transaction) }
  }

  static func settings(home: String = "EUR", budgetMinor: Int64? = nil) -> AccountSettingsRecord {
    let home = currency(home)
    return AccountSettingsRecord(defaultCurrency: home, enabledCurrencies: [home], monthlyBudget: budgetMinor.map { MoneyAmount(amountMinor: $0, currency: home) })
  }

  static func expense(
    _ number: Int, _ amountMinor: Int64, _ currency: String, on date: String, category: String = "food", merchant: String? = nil, note: String? = nil,
    loggedAt hour: Int = 12
  ) -> ExpenseRecord {
    ExpenseRecord(
      id: id(number), amountMinor: amountMinor, currency: self.currency(currency), occurredOn: self.date(date), category: self.category(category), merchant: merchant,
      note: note, loggedAtMillis: millis(self.date(date), hour: hour))
  }

  static func rate(_ base: String, _ quote: String, on date: String, _ rate: String) -> FxRateRecord {
    FxRateRecord(base: currency(base), quote: currency(quote), date: self.date(date), rate: decimal(rate))
  }

  /// Seeds `store` with records through their typed writes.
  static func seed(_ store: VaultStore, _ records: [any MemoirRecord]) async throws {
    try await store.write { transaction in
      for record in records { try record.create(in: &transaction) }
    }
  }

  static func first<Value: Sendable>(_ stream: AsyncThrowingStream<Value, any Error>, after skip: Int = 0) async throws -> Value {
    var iterator = stream.makeAsyncIterator()
    for _ in 0..<skip { _ = try await iterator.next() }
    guard let value = try await iterator.next() else { throw MemoirFixtureError(description: "the stream finished without a value") }
    return value
  }
}
