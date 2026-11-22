import Foundation
import MemoirCore
import ShadowStore

/// What the expense and subscription forms offer, read once when a form opens: the home currency, the currencies to pick from and the categories.
nonisolated struct MoneyOptions: Sendable, Equatable {
  /// memoir-web `CURRENCIES` (`lib/data/finance.types.ts:16-36`), offered after the account's enabled currencies.
  static let referenceCurrencies: [CurrencyCode] = [
    "EUR", "USD", "GBP", "NOK", "SEK", "DKK", "CHF", "JPY", "INR", "AED", "AUD", "CAD", "NZD", "SGD", "HKD", "PLN", "CZK", "ZAR", "BRL",
  ].compactMap(CurrencyCode.init)

  let home: CurrencyCode?
  let enabled: [CurrencyCode]
  let categories: [CategoryEntry]
  let today: LocalDate

  static func load(_ context: MemoirScreenContext) async throws -> MoneyOptions {
    let today = try await context.today().date
    let book = try await context.stores.main.read { transaction in try MoneyBook.load(from: transaction) }
    let categories = try CategoriesOverview.make(book, today: today).categories
    return MoneyOptions(home: book.settings?.defaultCurrency, enabled: book.settings?.enabledCurrencies ?? [], categories: categories, today: today)
  }

  /// The home currency first, then the other enabled ones, then memoir-web's list; `current` leads when it is in none of them.
  func currencies(including current: CurrencyCode?) -> [CurrencyCode] {
    var ordered = [CurrencyCode]()
    for code in [home].compactMap(\.self) + enabled + Self.referenceCurrencies where !ordered.contains(code) && MoneyText.exponent(of: code) != nil {
      ordered.append(code)
    }
    guard let current, !ordered.contains(current) else { return ordered }
    return [current] + ordered
  }

  /// memoir-web `availableCategories`: the categories not archived, and the one already chosen even when it is.
  func categories(including selected: CategoryKey?) -> [CategoryEntry] {
    categories.filter { !$0.isArchived || $0.key == selected }
  }

  func name(of key: CategoryKey) -> String {
    MoneyLabels.categoryName(key, label: categories.first { $0.key == key }?.label)
  }
}
