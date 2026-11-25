import Foundation
import ShadowCore
import ShadowStore

/// The checks `ExpenseEdits` runs on the part of an expense paid from savings and the goal it buys, against the vault as the write sees it on the
/// account's day. They run when the expense is written, never against an earlier day's thresholds.
///
/// - The part is above zero and at most the amount, checked whenever either moves.
/// - A goal named afresh, or one whose purchase draws more, must be active and out of its cooling-off: created at least `SavingsRules.coolingOffDays`
///   before both the expense's date and today, so dating the purchase ahead does not shorten it.
/// - A new or larger draw that buys no goal must be a one-off: the whole amount, in its budget's currency, at least
///   `BudgetBook.oneOffThreshold(of:on:today:)`; an amount still waiting for a rate, or a budget without a threshold, is refused.
/// - A new or larger draw must fit what savings have available, its own earlier draw put back first, in home. A draw whose home amount waits for a rate is
///   refused until the rate is recorded, since savings cannot know what it takes.
///
/// A draw that stays or falls, with the goal unchanged (a refund, an edit of the note), is checked no further, so an expense that drew in an earlier
/// month never becomes unsaveable.
enum SavingsWithdrawals {
  static func check(_ edited: ExpenseRecord, replacing current: ExpenseRecord?, issuer: CommandIssuer, in transaction: borrowing WriteTransaction)
    throws(CommandIssueError)
  {
    let draw = edited.savingsPortionMinor
    if edited.fromSavingsMinor != current?.fromSavingsMinor || edited.amountMinor != current?.amountMinor, let part = edited.fromSavingsMinor {
      guard part > 0 else { throw .refused(.finance(.savingsNotPositive(part))) }
      guard part <= edited.amountMinor else { throw .refused(.finance(.savingsExceedsAmount(savings: part, amount: edited.amountMinor))) }
    }
    let earlier = current?.savingsPortionMinor ?? 0
    let raised = draw > earlier
    let goalMoved = edited.goal != current?.goal
    let checksGoal = edited.goal != nil && (goalMoved || raised)
    guard checksGoal || (draw > 0 && (raised || goalMoved)) else { return }
    let source = ReadTransaction(database: transaction.database, registry: MemoirSchema.mainRegistry)
    let book: SavingsBook
    let subscriptions: [UUID: SubscriptionRecord]
    do throws(MemoirReadError) {
      book = try SavingsBook.load(from: source)
    } catch {
      throw CommandIssueError(reading: error)
    }
    do throws(StoreError) {
      subscriptions = Dictionary(try ReadSources.listing(SubscriptionRecord.self, in: source).records.map { ($0.id, $0) }) { first, _ in first }
    } catch {
      throw .record(.store(error))
    }
    let today = try issuer.accountToday(openDay: book.budgets.zone.openDay)
    do throws(FinanceError) {
      if checksGoal, let goal = edited.goal {
        try checkGoal(goal, buyingOn: edited.occurredOn, today: today, book: book)
      } else if draw > 0 {
        try checkOneOff(edited, today: today, book: book, subscriptions: subscriptions)
      }
      if raised { try checkAvailable(edited, draw: draw, today: today, book: book) }
    } catch {
      throw .refused(.finance(error))
    }
  }

  private static func checkGoal(_ id: UUID, buyingOn date: LocalDate, today: LocalDate, book: SavingsBook) throws(FinanceError) {
    guard let goal = book.goals.first(where: { $0.id == id }) else { throw .goalAbsent(id) }
    guard goal.state == .known(.active) else { throw .goalNotActive(id) }
    guard let buyFrom = goal.createdOn.adding(days: SavingsRules.coolingOffDays) else { throw .dateOutOfRange }
    guard min(date, today) >= buyFrom else { throw .coolingOffNotMet(buyFrom: buyFrom) }
  }

  private static func checkOneOff(_ expense: ExpenseRecord, today: LocalDate, book: SavingsBook, subscriptions: [UUID: SubscriptionRecord]) throws(FinanceError) {
    guard let converter = book.converter else { throw .settingsAbsent }
    let assigned = BudgetAssignment.assign(expense, subscriptions: subscriptions, among: book.budgets.assignments.budgets)
    guard let budget = book.budgets.liveBudgets(today: today).first(where: { $0.id == assigned.budget }) else { throw .budgetAbsent(assigned.budget) }
    let threshold = book.budgets.oneOffThreshold(of: budget, on: expense.occurredOn, today: today).minor
    switch converter.amount(of: expense, in: budget) {
    case .converted(let minor):
      guard let threshold, minor >= threshold else { throw .notOneOff(thresholdMinor: threshold) }
    case .awaitingRate:
      throw .savingsAwaitingRate
    case .unconvertible(let error):
      throw error
    }
  }

  private static func checkAvailable(_ expense: ExpenseRecord, draw: Int64, today: LocalDate, book: SavingsBook) throws(FinanceError) {
    guard let converter = book.converter else { throw .settingsAbsent }
    var portion = expense
    portion.amountMinor = draw
    let available = SavingsBalance.make(book, converter: converter, today: today, excluding: expense.id)
    switch converter.homeConverter.homeAmount(of: portion) {
    case .converted(let minor):
      guard Int128(minor) <= available.headroom else { throw .savingsInsufficient(availableMinor: available.availableMinor) }
    case .awaitingRate:
      throw .savingsAwaitingRate
    case .unconvertible(let error):
      throw error
    }
  }
}
