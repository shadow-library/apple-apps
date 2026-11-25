/// A category as the Categories screen lists it. A built-in category without its record is shown unarchived under the app's own name for it.
public struct CategoryEntry: Sendable, Hashable {
  public let key: CategoryKey
  public let isBuiltIn: Bool
  /// `category.setArchived` refuses to archive these (`FIN_007`): the uncategorised and subscriptions categories.
  public let isPermanent: Bool
  /// The label its record holds, if any.
  public let label: String?
  public let isArchived: Bool
  public let essential: CategoryEssential
}

/// memoir-web `financeCategoriesView` (`lib/data/finance.provider.ts:576-581`): every category and its share of this month's spending.
public struct CategoriesOverview: Sendable, Hashable {
  public let categories: [CategoryEntry]
  /// `nil` until the vault has its settings; otherwise every category, largest first.
  public let thisMonth: [CategorySlice]?
  public let uncategorised: CategorySlice?

  public static func make(_ book: MoneyBook, today: LocalDate) throws(FinanceError) -> CategoriesOverview {
    let records = Dictionary(book.categoryRecords.map { ($0.categoryKey, $0) }) { first, _ in first }
    let essentials = book.essentials
    let entries = book.categoryKeys.map { key in
      CategoryEntry(
        key: key, isBuiltIn: MoneyBook.builtInCategories.contains(key), isPermanent: CategoryArchival.permanentCategories.contains(key.key),
        label: records[key]?.label, isArchived: records[key]?.archived ?? false,
        essential: essentials.essential(key))
    }
    guard let converter = book.converter else { return CategoriesOverview(categories: entries, thisMonth: nil, uncategorised: nil) }
    guard let month = DateSpan.month(of: today) else { throw .dateOutOfRange }
    let slices = try book.breakdown(book.expenses.filter { month.contains($0.occurredOn) }, converter: converter)
    return CategoriesOverview(categories: entries, thisMonth: slices, uncategorised: slices.first { $0.category == MoneyBook.uncategorised })
  }
}
