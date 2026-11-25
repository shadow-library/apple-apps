import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// What the expense form needs to offer paying part from savings, read once when it opens: savings as they stand (what can be drawn, the goals) and the
/// budget book the one-off threshold of the expense's budget comes from. `ExpenseEdits` checks it all again inside the write.
nonisolated struct SavingsDrawOptions: Sendable, Equatable {
  let overview: SavingsOverview
  let book: BudgetBook

  /// Nil before the vault has settings.
  static func load(in transaction: ReadTransaction, today: LocalDate) throws -> SavingsDrawOptions? {
    let savings = try SavingsBook.load(from: transaction)
    return try SavingsOverview.make(savings, today: today).map { SavingsDrawOptions(overview: $0, book: savings.budgets) }
  }

  var home: CurrencyCode { overview.home }

  /// The goals a purchase may name: the active ones, those filling in fill order, then any in another currency.
  var activeGoals: [SavingsGoalRecord] {
    overview.allocation.active.map(\.goal) + overview.allocation.otherCurrency.filter { $0.state == .known(.active) }
  }

  func goal(_ id: UUID) -> SavingsGoalRecord? {
    let allocation = overview.allocation
    return (allocation.active.map(\.goal) + allocation.settled.map(\.goal) + allocation.otherCurrency).first { $0.id == id }
  }

  func oneOffThreshold(of budget: LiveBudget, on date: LocalDate) -> OneOffThreshold {
    book.oneOffThreshold(of: budget, on: date, today: overview.today)
  }
}

struct GoalChoice: Hashable, Identifiable {
  let id: UUID
  let name: String
}

/// "Pay part from savings" on the expense form: the part in the expense's currency, the goal it buys, and what the core will hold the draw to.
struct SavingsDrawSection: View {
  @Bindable var form: ExpenseForm
  @Environment(\.locale) private var locale

  var body: some View {
    Section {
      MoneyAmountField(text: $form.fromSavingsText, currency: form.currency, issue: form.fromSavingsIssue, label: Text("From savings", tableName: "Money"))
      Picker(selection: $form.goal) {
        Text("No goal", tableName: "Money").tag(UUID?.none)
        ForEach(form.goalChoices) { choice in Text(verbatim: choice.name).tag(Optional(choice.id)) }
      } label: {
        Text("Buys a goal", tableName: "Money")
      }
      .pickerStyle(.menu)
    } header: {
      Text("Pay part from savings", tableName: "Money")
    } footer: {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        ForEach(form.savingsNotes(locale: locale), id: \.self) { note in Text(verbatim: note) }
      }
    }
  }
}
