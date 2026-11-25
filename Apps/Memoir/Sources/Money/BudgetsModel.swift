import Foundation
import MemoirCore
import Observation
import ShadowAppShell

/// Every live budget's current period for the account's day, followed as expenses, budgets and rates change; a budget but Home deleted from its row.
@MainActor
@Observable
final class BudgetsModel {
  let standings = MoneyFeed<BudgetStandings?>()
  private(set) var working: Set<UUID> = []
  private(set) var failure: PresentedError?
  @ObservationIgnored let context: MemoirScreenContext

  init(context: MemoirScreenContext) {
    self.context = context
  }

  func run() async {
    defer { standings.stop() }
    var followed: LocalDate?
    do {
      for try await today in context.observeToday() where today.date != followed {
        followed = today.date
        let stores = context.stores
        let date = today.date
        standings.follow { MoneyReads.observeBudgetStandings(in: stores, today: date) }
      }
    } catch {
      standings.fail(error)
    }
  }

  /// Home's currency, when it is not the account's: two devices set the vault up in different currencies, and Home kept the first.
  var homeCurrencyDiffers: CurrencyCode? {
    guard let standings = standings.state.value ?? nil, let home = standings.homeBudget, home.budget.currency != standings.home else { return nil }
    return home.budget.currency
  }

  func delete(_ id: UUID) async -> Bool {
    guard id != HomeBudget.id, !working.contains(id) else { return false }
    working.insert(id)
    failure = nil
    defer { working.remove(id) }
    do {
      try await context.writer.write { _, transaction in try BudgetEdits.delete(id, in: &transaction) }
      return true
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
  }
}
