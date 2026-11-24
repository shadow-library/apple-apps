import Foundation
import MemoirCore
import ShadowCore
import ShadowStore

enum BudgetFixture {
  static func id(_ number: Int) -> UUID {
    MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-%012x", 0xB000 + number))
  }

  static func date(_ text: String) -> LocalDate {
    guard let date = LocalDate(isoString: text) else { preconditionFailure("\(text) is a date") }
    return date
  }

  static func currency(_ text: String) -> CurrencyCode {
    guard let code = CurrencyCode(text) else { preconditionFailure("\(text) is a currency code") }
    return code
  }

  static let eur = currency("EUR")
  static let usd = currency("USD")
  static let jpy = currency("JPY")
  static let gbp = currency("GBP")

  static func monthly(_ name: String, _ currency: CurrencyCode, limitMinor: Int64, oneOffFromMinor: Int64? = nil) -> BudgetDraft {
    BudgetDraft(name: name, currency: currency, limitMinor: limitMinor, period: .monthly, oneOffFromMinor: oneOffFromMinor)
  }

  static func trip(_ name: String, _ currency: CurrencyCode, limitMinor: Int64, from: String, through: String) -> BudgetDraft {
    BudgetDraft(name: name, currency: currency, limitMinor: limitMinor, period: .trip(from: date(from), through: date(through)))
  }

  static func store(home: CurrencyCode = eur, budgetMinor: Int64? = 50_000, wallClock: @escaping @Sendable () -> Date = { Date() }) async throws -> VaultStore {
    let store = try MemoirStore.openInMemory(.main, wallClock: wallClock)
    _ = try await store.write { transaction in try FinanceFixture.settings(home: home, budgetMinor: budgetMinor).create(in: &transaction) }
    return store
  }

  static func budgets(in store: VaultStore) async throws -> Budgets {
    try await store.read { transaction in try Budgets.live(in: transaction) }
  }

  static func record(_ id: UUID, in store: VaultStore) async throws -> BudgetRecord? {
    try await store.read { transaction in try BudgetRecord.read(id: id, in: transaction) }.entry?.record
  }

  static func refusal(in store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws(FinanceError) -> Void) async throws -> FinanceError? {
    do {
      _ = try await store.write { transaction in try body(&transaction) }
      return nil
    } catch {
      guard case .aborted(let inner as FinanceError) = error else { throw error }
      return inner
    }
  }

  static func entries(_ records: [(BudgetRecord, removed: Bool)]) -> MemoirListing<MemoirEntry<BudgetRecord>> {
    MemoirListing(entries: records.map { MemoirEntry(record: $0.0, isRemoved: $0.removed) }, unreadable: 0)
  }
}
