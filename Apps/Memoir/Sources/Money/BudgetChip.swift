import Foundation
import MemoirCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

struct BudgetChoice: Hashable, Identifiable, Sendable {
  let id: UUID
  let name: String
  let currency: CurrencyCode
}

/// The budget chip of the expense and subscription forms: the budget the assignment rule picks, and the owner's override of it. An override the form
/// opened with that names a budget no longer live stays as it was unless the owner picks again, so opening and saving never rewrites it.
struct BudgetPick: Equatable, Sendable {
  private(set) var budgets: Budgets
  var override: UUID?
  let homeCurrency: CurrencyCode
  private let opening: UUID?
  private let stored: UUID?

  /// Nil before the vault has settings, which name the home currency.
  init?(budgets: Budgets, stored: UUID?) {
    guard let homeCurrency = budgets.homeCurrency else { return nil }
    self.budgets = budgets
    self.homeCurrency = homeCurrency
    self.stored = stored
    let shown = stored.flatMap { id in id == HomeBudget.id || budgets.budget(id) != nil ? id : nil }
    override = shown
    opening = shown
  }

  var isMoved: Bool { override != opening }

  /// What the record's override field is saved as.
  var written: UUID? { isMoved ? override : stored }

  /// The override to check is still live inside the write; nil when the owner left it as it was or chose the automatic budget.
  var movedOverride: UUID? { isMoved ? override : nil }

  /// Home, then every other budget whose period holds `date`, and the chosen one even when it no longer does.
  func choices(on date: LocalDate) -> [BudgetChoice] {
    var choices = [BudgetChoice(id: HomeBudget.id, name: BudgetCopy.home, currency: homeCurrency)]
    for budget in budgets.live where !budget.isHome && (budget.covers(date) || budget.id == override) {
      choices.append(BudgetChoice(id: budget.id, name: BudgetCopy.name(of: budget), currency: budget.currency))
    }
    return choices
  }

  func assignment(currency: CurrencyCode, on date: LocalDate, subscriptionOverride: UUID? = nil) -> BudgetAssignment {
    BudgetAssignment.assign(currency: currency, occurredOn: date, override: override, subscriptionOverride: subscriptionOverride, among: budgets)
  }

  func automatic(currency: CurrencyCode, on date: LocalDate, subscriptionOverride: UUID? = nil) -> BudgetAssignment {
    BudgetAssignment.assign(currency: currency, occurredOn: date, subscriptionOverride: subscriptionOverride, among: budgets)
  }

  func name(of id: UUID) -> String {
    budgets.budget(id).map(BudgetCopy.name(of:)) ?? BudgetCopy.name(id: id, stored: nil)
  }

  /// The chip's footer: where it counts and why, or that the chosen budget does not hold the date.
  func explanation(currency: CurrencyCode, on date: LocalDate, subscriptionOverride: UUID? = nil, locale: Locale) -> String {
    let assignment = assignment(currency: currency, on: date, subscriptionOverride: subscriptionOverride)
    if let override, override != assignment.budget {
      let day = MoneyDates.text(date, locale: locale)
      return String(localized: "\(name(of: override)) doesn’t cover \(day), so this counts in \(name(of: assignment.budget)).", table: "Money")
    }
    return BudgetCopy.reason(assignment, currency: currency, homeCurrency: homeCurrency)
  }

  /// After a write refused a budget deleted elsewhere: the live budgets read again and the automatic budget chosen.
  mutating func refresh(_ budgets: Budgets) {
    if budgets.homeCurrency != nil { self.budgets = budgets }
    override = nil
  }

  /// Refuses an override naming a budget deleted since the form opened, inside the write that would save it.
  nonisolated static func requireLive(_ id: UUID?, in transaction: borrowing WriteTransaction) throws(FinanceError) {
    guard let id, id != HomeBudget.id else { return }
    guard try Budgets.live(in: transaction).budget(id) != nil else { throw .budgetAbsent(id) }
  }

  static func isAbsentBudget(_ error: any Error) -> Bool {
    guard case .budgetAbsent? = BudgetCopy.financeError(error) else { return false }
    return true
  }
}

/// The chip as a form section: the automatic budget or one the owner picks, with why it counts there.
struct BudgetChipSection: View {
  @Binding var pick: BudgetPick
  let currency: CurrencyCode
  let date: LocalDate
  var subscriptionOverride: UUID?
  var footnote: Text?
  @Environment(\.locale) private var locale

  var body: some View {
    Section {
      Picker(selection: $pick.override) {
        Text("Automatic: \(pick.name(of: pick.automatic(currency: currency, on: date, subscriptionOverride: subscriptionOverride).budget))", tableName: "Money")
          .tag(UUID?.none)
        ForEach(pick.choices(on: date)) { choice in
          Text(verbatim: "\(choice.name) · \(choice.currency.code)").tag(Optional(choice.id))
        }
      } label: {
        Text("Budget", tableName: "Money")
      }
      .pickerStyle(.menu)
    } footer: {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        Text(verbatim: pick.explanation(currency: currency, on: date, subscriptionOverride: subscriptionOverride, locale: locale))
        if let footnote { footnote }
      }
    }
  }
}
