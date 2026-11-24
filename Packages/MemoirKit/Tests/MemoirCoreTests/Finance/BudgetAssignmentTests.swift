import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Budget assignment", TestTimeLimit.quick)
struct BudgetAssignmentTests {
  private typealias F = BudgetFixture

  private static let created = F.date("2026-11-01")
  private static let home = BudgetRecord(id: HomeBudget.id, currency: F.eur, period: .monthly, createdOn: created)
  private static let dollars = BudgetRecord(id: F.id(1), name: "Dollars", currency: F.usd, limitMinor: 1, period: .monthly, createdOn: created)
  private static let lisbon = BudgetRecord(
    id: F.id(2), name: "Lisbon", currency: F.eur, limitMinor: 1, period: .trip(from: F.date("2026-12-10"), through: F.date("2026-12-20")), createdOn: created)
  private static let gone = BudgetRecord(id: F.id(3), name: "Gone", currency: F.gbp, limitMinor: 1, period: .monthly, createdOn: created)
  private static let subscription = F.id(40)

  private static var budgets: Budgets {
    Budgets(F.entries([(home, false), (dollars, false), (lisbon, false), (gone, true)]), settings: FinanceFixture.settings(home: F.eur))
  }

  private static func assign(_ currency: CurrencyCode, on date: String, override: UUID? = nil, subscriptionOverride: UUID? = nil) -> BudgetAssignment {
    BudgetAssignment.assign(currency: currency, occurredOn: F.date(date), override: override, subscriptionOverride: subscriptionOverride, among: budgets)
  }

  private static func expense(_ number: Int, _ currency: CurrencyCode, on date: String, budget: UUID? = nil, cycleOf subscription: UUID? = nil) throws -> ExpenseRecord {
    let category = try MemoirStoreFixture.category("food")
    return ExpenseRecord(
      id: FinanceFixture.expenseID(number), amountMinor: 100, currency: currency, occurredOn: F.date(date), category: category, budget: budget,
      cycle: subscription.map { ExpenseCycleSeed(subscription: $0, amountMinor: 100, occurredOn: F.date(date), category: category) }, loggedAtMillis: 1)
  }

  private static func subscription(budget: UUID?) throws -> SubscriptionRecord {
    SubscriptionRecord(
      id: subscription, name: "Gym", amountMinor: 100, currency: F.usd, frequency: .known(.monthly), billingDay: 1, anchorOn: created,
      category: try MemoirStoreFixture.category("subs"), budget: budget)
  }

  @Test func shouldAssignByOverrideThenTripThenCurrencyThenHome() {
    #expect(Self.assign(F.usd, on: "2026-12-12", override: Self.dollars.id) == BudgetAssignment(budget: Self.dollars.id, reason: .expenseOverride))
    #expect(Self.assign(F.usd, on: "2026-12-12") == BudgetAssignment(budget: Self.lisbon.id, reason: .trip), "a trip takes every currency spent on its dates")
    #expect(Self.assign(F.usd, on: "2026-12-10").budget == Self.lisbon.id)
    #expect(Self.assign(F.usd, on: "2026-12-20").budget == Self.lisbon.id)
    #expect(Self.assign(F.usd, on: "2026-12-21") == BudgetAssignment(budget: Self.dollars.id, reason: .currency))
    #expect(Self.assign(F.eur, on: "2026-12-21") == BudgetAssignment(budget: HomeBudget.id, reason: .home))
    #expect(Self.assign(F.jpy, on: "2026-12-21") == BudgetAssignment(budget: HomeBudget.id, reason: .home), "a currency with no budget counts in Home")
    #expect(Self.assign(F.eur, on: "2026-12-21", override: HomeBudget.id) == BudgetAssignment(budget: HomeBudget.id, reason: .expenseOverride))
  }

  @Test func shouldSkipAnOverrideThatIsDeletedUnknownOrATripNotHoldingTheDate() {
    #expect(Self.assign(F.gbp, on: "2026-12-12", override: Self.gone.id) == BudgetAssignment(budget: Self.lisbon.id, reason: .trip))
    #expect(Self.assign(F.gbp, on: "2026-12-21", override: Self.gone.id) == BudgetAssignment(budget: HomeBudget.id, reason: .home))
    #expect(Self.assign(F.usd, on: "2026-12-21", override: F.id(99)).budget == Self.dollars.id)
    #expect(Self.assign(F.usd, on: "2026-12-21", override: Self.lisbon.id) == BudgetAssignment(budget: Self.dollars.id, reason: .currency))
  }

  @Test func shouldCountACycleExpenseWhereItsSubscriptionSaysUnlessItHasItsOwnOverride() throws {
    let subscriptions = [Self.subscription: try Self.subscription(budget: Self.dollars.id)]
    let cycle = try Self.expense(1, F.eur, on: "2026-12-12", cycleOf: Self.subscription)
    #expect(BudgetAssignment.assign(cycle, subscriptions: subscriptions, among: Self.budgets) == BudgetAssignment(budget: Self.dollars.id, reason: .subscriptionOverride))
    let own = try Self.expense(2, F.eur, on: "2026-12-12", budget: HomeBudget.id, cycleOf: Self.subscription)
    #expect(BudgetAssignment.assign(own, subscriptions: subscriptions, among: Self.budgets) == BudgetAssignment(budget: HomeBudget.id, reason: .expenseOverride))
    let deadOwn = try Self.expense(3, F.eur, on: "2026-12-21", budget: Self.gone.id, cycleOf: Self.subscription)
    #expect(BudgetAssignment.assign(deadOwn, subscriptions: subscriptions, among: Self.budgets).reason == .subscriptionOverride)
    let manual = try Self.expense(4, F.eur, on: "2026-12-21")
    #expect(BudgetAssignment.assign(manual, subscriptions: subscriptions, among: Self.budgets).reason == .home, "only a cycle's expense follows its subscription")
    let deleted = [Self.subscription: try Self.subscription(budget: Self.gone.id)]
    #expect(BudgetAssignment.assign(cycle, subscriptions: deleted, among: Self.budgets) == BudgetAssignment(budget: Self.lisbon.id, reason: .trip))
    #expect(BudgetAssignment.assign(cycle, subscriptions: [:], among: Self.budgets).reason == .trip, "an unknown subscription has no override")
  }

  @Test func shouldPickTheSameBudgetOnEveryDeviceWhenMergedBudgetsCollide() {
    let porto = BudgetRecord(
      id: F.id(0), name: "Porto", currency: F.usd, limitMinor: 1, period: .trip(from: F.date("2026-12-15"), through: F.date("2026-12-25")),
      createdOn: F.date("2026-11-05"))
    let moreDollars = BudgetRecord(id: F.id(0), name: "More", currency: F.usd, limitMinor: 1, period: .monthly, createdOn: F.date("2026-10-01"))
    let euros = BudgetRecord(id: F.id(5), name: "Euros", currency: F.eur, limitMinor: 1, period: .monthly, createdOn: F.date("2026-10-01"))
    for records in [[Self.home, Self.lisbon, porto], [porto, Self.lisbon, Self.home]] {
      let budgets = Budgets(F.entries(records.map { ($0, false) }), settings: nil)
      #expect(BudgetAssignment.assign(currency: F.usd, occurredOn: F.date("2026-12-16"), among: budgets).budget == Self.lisbon.id, "the trip created first wins")
    }
    let budgets = Budgets(F.entries([(Self.dollars, false), (moreDollars, false), (euros, false), (Self.home, false)]), settings: nil)
    #expect(BudgetAssignment.assign(currency: F.usd, occurredOn: F.date("2026-12-16"), among: budgets).budget == moreDollars.id)
    #expect(
      BudgetAssignment.assign(currency: F.eur, occurredOn: F.date("2026-12-16"), among: budgets).budget == HomeBudget.id, "Home outranks another monthly budget in its currency")
    #expect(budgets.live.map(\.id) == [HomeBudget.id, moreDollars.id, euros.id, Self.dollars.id])
  }

  @Test func shouldKeepHomeLiveAndUseTheAccountsCurrencyUntilHomeIsWritten() {
    let removedHome = Budgets(F.entries([(Self.home, true)]), settings: nil)
    #expect(removedHome.home?.id == HomeBudget.id, "Home cannot be deleted, so a removal is ignored")
    let unwritten = Budgets(F.entries([(Self.dollars, false)]), settings: FinanceFixture.settings(home: F.usd))
    #expect(unwritten.home == nil)
    #expect(unwritten.homeCurrency == F.usd)
    #expect(BudgetAssignment.assign(currency: F.usd, occurredOn: Self.created, among: unwritten) == BudgetAssignment(budget: HomeBudget.id, reason: .home))
  }

  @Test func shouldLoadTheLiveExpensesWithTheBudgetEachCountsIn() async throws {
    let store = try await F.store()
    let cycle = try Self.expense(1, F.eur, on: "2026-12-21", cycleOf: Self.subscription)
    let deleted = try Self.expense(2, F.usd, on: "2026-12-21")
    let dollars = try Self.expense(3, F.usd, on: "2026-12-21")
    _ = try await store.write { transaction in
      try BudgetEdits.create(F.monthly("Dollars", F.usd, limitMinor: 1), id: Self.dollars.id, today: Self.created, in: &transaction)
      try Self.subscription(budget: Self.dollars.id).create(in: &transaction)
      for expense in [cycle, deleted, dollars] { try expense.create(in: &transaction) }
      try ExpenseRecord.remove(deleted.ref, in: &transaction)
    }
    let loaded = try await store.read { transaction in try BudgetAssignments.load(from: transaction) }
    #expect(loaded.expenses.map(\.id) == [cycle.id, dollars.id])
    #expect(loaded.assignments[cycle.id]?.reason == .subscriptionOverride)
    #expect(loaded.expenses(assignedTo: Self.dollars.id).map(\.id) == [cycle.id, dollars.id])
    #expect(loaded.expenses(assignedTo: HomeBudget.id).isEmpty)
  }
}
