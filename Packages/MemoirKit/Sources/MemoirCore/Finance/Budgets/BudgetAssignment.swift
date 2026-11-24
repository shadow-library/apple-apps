import Foundation
import ShadowStore

/// The one budget an expense counts in, derived when read, so a budget created later pulls in the expenses it now covers. An override counts only
/// while its budget is live and holds the expense's date; Home is always there to fall back on.
public struct BudgetAssignment: Hashable, Sendable {
  public enum Reason: String, Hashable, Sendable {
    case expenseOverride = "expense_override"
    case subscriptionOverride = "subscription_override"
    case trip
    case currency
    case home
  }

  public let budget: UUID
  public let reason: Reason

  public init(budget: UUID, reason: Reason) {
    self.budget = budget
    self.reason = reason
  }

  public static func assign(
    currency: CurrencyCode, occurredOn date: LocalDate, override: UUID? = nil, subscriptionOverride: UUID? = nil, among budgets: Budgets
  ) -> BudgetAssignment {
    if let override, budgets.holds(override, on: date) { return BudgetAssignment(budget: override, reason: .expenseOverride) }
    if let subscriptionOverride, budgets.holds(subscriptionOverride, on: date) { return BudgetAssignment(budget: subscriptionOverride, reason: .subscriptionOverride) }
    if let trip = budgets.live.first(where: { $0.record.period != .monthly && $0.covers(date) }) { return BudgetAssignment(budget: trip.id, reason: .trip) }
    if currency != budgets.homeCurrency, let monthly = budgets.live.first(where: { !$0.isHome && $0.record.period == .monthly && $0.currency == currency }) {
      return BudgetAssignment(budget: monthly.id, reason: .currency)
    }
    return BudgetAssignment(budget: HomeBudget.id, reason: .home)
  }

  /// A subscription cycle's expense without an override of its own counts where its subscription's override says, even once the subscription is deleted.
  public static func assign(_ expense: ExpenseRecord, subscriptions: [UUID: SubscriptionRecord], among budgets: Budgets) -> BudgetAssignment {
    let subscriptionOverride = expense.cycle.flatMap { subscriptions[$0.subscription]?.budget }
    return assign(currency: expense.currency, occurredOn: expense.occurredOn, override: expense.budget, subscriptionOverride: subscriptionOverride, among: budgets)
  }
}

/// The live expenses with the budget each counts in, read in one transaction.
public struct BudgetAssignments: Equatable, Sendable {
  public let budgets: Budgets
  public let expenses: [ExpenseRecord]
  public let assignments: [UUID: BudgetAssignment]

  public init(budgets: Budgets, expenses: [ExpenseRecord], subscriptions: [UUID: SubscriptionRecord]) {
    self.budgets = budgets
    self.expenses = expenses
    assignments = Dictionary(expenses.map { ($0.id, BudgetAssignment.assign($0, subscriptions: subscriptions, among: budgets)) }) { first, _ in first }
  }

  public static func load<Source: RecordSource & ~Copyable>(from source: borrowing Source) throws(FinanceError) -> BudgetAssignments {
    let expenses: MemoirListing<MemoirEntry<ExpenseRecord>>
    let subscriptions: MemoirListing<MemoirEntry<SubscriptionRecord>>
    do throws(StoreError) {
      expenses = try ExpenseRecord.listing(in: source)
      subscriptions = try SubscriptionRecord.listing(in: source)
    } catch {
      throw FinanceError(error)
    }
    return BudgetAssignments(
      budgets: try Budgets.live(in: source), expenses: expenses.entries.filter { !$0.isRemoved }.map(\.record),
      subscriptions: Dictionary(subscriptions.entries.map { ($0.record.id, $0.record) }) { first, _ in first })
  }

  public func expenses(assignedTo budget: UUID) -> [ExpenseRecord] {
    expenses.filter { assignments[$0.id]?.budget == budget }
  }
}

extension Budgets {
  func holds(_ id: UUID, on date: LocalDate) -> Bool {
    id == HomeBudget.id || budget(id)?.covers(date) == true
  }
}
