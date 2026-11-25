/// Whether a category is essential, and whether the owner said so or the default did.
public enum CategoryEssential: Sendable, Hashable {
  case byDefault(Bool)
  case byOwner(Bool)

  public var isEssential: Bool {
    switch self {
    case .byDefault(let essential), .byOwner(let essential): essential
    }
  }
}

/// Which categories are essential: the owner's choice on the category's record, else the default. Of the built-in categories, the ones a household cannot
/// simply spend less on are essential: groceries (the weekly shop), transport (getting to work), bills (power, water, phone), health and home (rent,
/// repairs). Eating out, shopping and subscriptions are what a goal's lever may suggest trimming; uncategorised and the owner's own categories are not
/// essential until the owner says so.
public struct CategoryEssentials: Sendable, Hashable {
  public static let essentialByDefault: Set<CategoryKey> = Set(["groceries", "transport", "bills", "health", "home"].compactMap(CategoryKey.init))

  private let owner: [CategoryKey: Bool]

  public init(records: some Sequence<ExpenseCategoryRecord>) {
    var owner = [CategoryKey: Bool]()
    for record in records { if let essential = record.essential { owner[record.categoryKey] = essential } }
    self.owner = owner
  }

  public func essential(_ category: CategoryKey) -> CategoryEssential {
    owner[category].map(CategoryEssential.byOwner) ?? .byDefault(Self.essentialByDefault.contains(category))
  }

  public func isEssential(_ category: CategoryKey) -> Bool {
    essential(category).isEssential
  }
}

extension MoneyBook {
  public var essentials: CategoryEssentials { CategoryEssentials(records: categoryRecords) }
}
