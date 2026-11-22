import Foundation
import ShadowText

public struct ExpenseQuery: Sendable, Hashable {
  /// The days to list; `nil` lists every day.
  public var span: DateSpan?
  /// Matched against the note and the merchant only, case-insensitively, as memoir-web's `matchesSearch` (`lib/data/finance.provider.ts:413-417`).
  public var search: String
  public var category: CategoryKey?
  public var page: PageRequest

  public init(span: DateSpan?, search: String = "", category: CategoryKey? = nil, page: PageRequest = .all) {
    self.span = span
    self.search = search
    self.category = category
    self.page = page
  }
}

public struct ExpenseRow: Sendable, Equatable {
  public let expense: ExpenseRecord
  public let inHome: HomeAmount
}

public struct ExpenseListing: Sendable, Equatable {
  /// `nil` until the vault has its settings, and then every row is `.awaitingRate`.
  public let home: CurrencyCode?
  public let rows: ReadPage<ExpenseRow>
  public let unreadable: Int

  /// memoir-web `financeExpensePage` (`finance.provider.ts:508-516`): newest first by date, then by when it was logged; the id breaks the last tie.
  public static func make(_ book: MoneyBook, query: ExpenseQuery) throws(FinanceError) -> ExpenseListing {
    let needle = query.search.jsTrim().jsToLowerCase()
    let matched = book.expenses.filter { expense in
      (query.span?.contains(expense.occurredOn) ?? true) && (query.category.map { book.category(of: expense) == $0 } ?? true)
        && (needle.isEmpty || "\(expense.note ?? "") \(expense.merchant ?? "")".jsToLowerCase().jsIncludes(needle))
    }
    .sorted { first, second in
      if first.occurredOn != second.occurredOn { return first.occurredOn > second.occurredOn }
      if first.loggedAtMillis != second.loggedAtMillis { return first.loggedAtMillis > second.loggedAtMillis }
      return first.id.uuidString > second.id.uuidString
    }
    let converter = book.converter
    let rows = matched.map { ExpenseRow(expense: $0, inHome: converter?.homeAmount(of: $0) ?? .awaitingRate) }
    return ExpenseListing(home: book.home, rows: ReadPage(rows, page: query.page), unreadable: book.unreadable)
  }
}
