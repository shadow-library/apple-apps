import Foundation
import ShadowCore
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

/// What a refund left of an expense: nothing, or the total refunded while the rest still stands.
public enum ExpenseRefundState: Sendable, Hashable {
  case full
  case partial(refundedMinor: Int64)

  public init?(_ expense: ExpenseRecord, refundedMinor: Int64?) {
    guard let refundedMinor, refundedMinor > 0 else { return nil }
    self = expense.amountMinor == 0 ? .full : .partial(refundedMinor: refundedMinor)
  }

  /// A refund is in force while the latest edit that moved an expense's amount is a refund; the total runs back over the refunds in a row.
  static func refunded(_ changes: [AppendedEntry<ExpenseChangeRecord>]) -> [UUID: Int64] {
    var moves = [UUID: [(clock: HLCTimestamp, refund: Bool, by: Int64)]]()
    for entry in changes {
      let change = entry.record
      guard let by = change.changes.lazy.compactMap({ move -> Int64? in if case .amount(let from, let to) = move { from - to } else { nil } }).first else { continue }
      let refund = if case .known(.refund)? = change.reason { true } else { false }
      moves[change.expense, default: []].append((entry.clock, refund, by))
    }
    var totals = [UUID: Int64]()
    for (expense, list) in moves {
      var total: Int64 = 0
      for move in list.sorted(by: { $0.clock < $1.clock }).reversed() {
        guard move.refund else { break }
        total += move.by
      }
      if total > 0 { totals[expense] = total }
    }
    return totals
  }
}

public struct ExpenseRow: Sendable, Equatable {
  public let expense: ExpenseRecord
  public let inHome: HomeAmount

  public let refund: ExpenseRefundState?
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
    let rows = matched.map {
      ExpenseRow(expense: $0, inHome: converter?.homeAmount(of: $0) ?? .awaitingRate, refund: ExpenseRefundState($0, refundedMinor: book.refundedMinor[$0.id]))
    }
    return ExpenseListing(home: book.home, rows: ReadPage(rows, page: query.page), unreadable: book.unreadable)
  }
}
