import Foundation
import MemoirCore
import SwiftUI

enum MoneyRoute: Hashable {
  case expense(UUID)
  case newExpense
  /// Every expense of a scope; a category in it is memoir-web's `?category=` filter.
  case expenses(ExpenseListScope)
  case subscriptions
  case subscription(UUID)
  case newSubscription
  case categories
  case budgets
  case budget(UUID)
  case newBudget
}

struct MoneyRouteView: View {
  let route: MoneyRoute
  let context: MemoirScreenContext

  var body: some View {
    switch route {
    case .expense(let id): ExpenseDetailView(id: id, context: context)
    case .newExpense: ExpenseFormScreen(editing: nil, context: context)
    case .expenses(let scope): ExpensesView(scope: scope, context: context)
    case .subscriptions: SubscriptionsView(context: context)
    case .subscription(let id): SubscriptionFormScreen(editing: id, context: context)
    case .newSubscription: SubscriptionFormScreen(editing: nil, context: context)
    case .categories: CategoriesView(context: context)
    case .budgets: BudgetsView(context: context)
    case .budget(let id): BudgetFormScreen(editing: id, context: context)
    case .newBudget: BudgetFormScreen(editing: nil, context: context)
    }
  }
}
