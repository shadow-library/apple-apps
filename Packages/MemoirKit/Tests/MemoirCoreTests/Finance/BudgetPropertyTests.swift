import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Budget properties", TestTimeLimit.property)
struct BudgetPropertyTests {
  private typealias F = BudgetFixture

  private static let currencies = [F.eur, F.usd, F.jpy, F.gbp]
  private static let firstDay = F.date("2026-10-01")
  private static let today = F.date("2026-11-21")

  private static func day(_ generator: inout SeededGenerator, within days: Int = 120) -> LocalDate {
    firstDay.adding(days: generator.int(in: 0...days)) ?? firstDay
  }

  private static func randomBudget(_ number: Int, _ generator: inout SeededGenerator) -> BudgetRecord {
    let period: BudgetPeriodKind
    if generator.chance(0.5) {
      period = .monthly
    } else {
      let from = day(&generator)
      period = .trip(from: from, through: from.adding(days: generator.int(in: 0...20)) ?? from)
    }
    return BudgetRecord(
      id: F.id(number), name: "Budget \(number)", currency: generator.pick(from: currencies), limitMinor: 1, period: period, createdOn: day(&generator))
  }

  @Test func shouldCountEveryExpenseInExactlyOneLiveBudgetThatHoldsItsDate() throws {
    let category = try MemoirStoreFixture.category("food")
    try forAll(iterations: 300) { generator in
      var records = [(BudgetRecord, removed: Bool)]()
      if generator.chance(0.9) {
        records.append((BudgetRecord(id: HomeBudget.id, currency: F.eur, period: .monthly, createdOn: Self.firstDay), removed: generator.chance(0.1)))
      }
      for number in 0..<generator.int(in: 0...6) { records.append((Self.randomBudget(number, &generator), removed: generator.chance(0.25))) }
      let candidates = records.map(\.0.id) + [HomeBudget.id, F.id(99)]
      let subscriptions = Dictionary(
        uniqueKeysWithValues: (0..<3).map { number in
          (
            F.id(50 + number),
            SubscriptionRecord(
              id: F.id(50 + number), name: "Plan", amountMinor: 1, currency: F.usd, frequency: .known(.monthly), billingDay: 1, anchorOn: Self.firstDay,
              category: category, budget: generator.chance(0.6) ? generator.pick(from: candidates) : nil)
          )
        })
      let expenses = (0..<generator.int(in: 1...10)).map { number in
        let date = Self.day(&generator, within: 150)
        let subscription = generator.chance(0.4) ? F.id(50 + generator.int(in: 0...3)) : nil
        return ExpenseRecord(
          id: FinanceFixture.expenseID(number), amountMinor: 1, currency: generator.pick(from: Self.currencies), occurredOn: date, category: category,
          budget: generator.chance(0.4) ? generator.pick(from: candidates) : nil,
          cycle: subscription.map { ExpenseCycleSeed(subscription: $0, amountMinor: 1, occurredOn: date, category: category) }, loggedAtMillis: 1)
      }
      let settings = generator.chance(0.8) ? FinanceFixture.settings(home: F.eur) : nil
      let budgets = Budgets(F.entries(records), settings: settings)
      let shuffled = Budgets(F.entries(generator.shuffled(records)), settings: settings)
      let assignments = BudgetAssignments(budgets: budgets, expenses: expenses, subscriptions: subscriptions)
      #expect(BudgetAssignments(budgets: shuffled, expenses: expenses, subscriptions: subscriptions).assignments == assignments.assignments)
      for expense in expenses {
        let assigned = try #require(assignments.assignments[expense.id])
        let live = budgets.budget(assigned.budget)
        #expect(assigned.budget == HomeBudget.id || live?.covers(expense.occurredOn) == true, "\(assigned) for \(expense.occurredOn)")
        #expect(records.contains { $0.0.id == assigned.budget && $0.removed && !$0.0.isHome } == false, "a deleted budget counts nothing")
        if let own = expense.budget, own == HomeBudget.id || budgets.budget(own)?.covers(expense.occurredOn) == true {
          #expect(assigned == BudgetAssignment(budget: own, reason: .expenseOverride))
        }
        if assigned.reason == .currency { #expect(live?.currency == expense.currency && live?.record.period == .monthly) }
        if assigned.reason == .home {
          #expect(budgets.live.contains { !$0.isHome && $0.record.period != .monthly && $0.covers(expense.occurredOn) } == false, "no trip held the date")
        }
      }
      let counted = Set(assignments.assignments.values.map(\.budget)).reduce(0) { $0 + assignments.expenses(assignedTo: $1).count }
      #expect(counted == expenses.count, "every expense is counted once")
    }
  }

  @Test func shouldStageEveryMonthlyLimitEditAsTheRulesSay() throws {
    try forAll(iterations: 300) { generator in
      var staging = BudgetStaging(base: Int64(generator.int(in: 0...10_000)), staged: nil)
      var day = Self.firstDay
      for _ in 0..<generator.int(in: 1...16) {
        day = day.adding(days: generator.int(in: 0...40)) ?? day
        let random = Int64(generator.int(in: 0...10_000))
        let current = staging.value(on: day)
        let limit = generator.pick(from: [current ?? random, staging.pending(on: day)?.amountMinor ?? random, random])
        guard limit != staging.latest(on: day) else { continue }
        let monthStart = try BudgetStaging.monthStart(of: day)
        let nextMonth = try BudgetStaging.nextMonthStart(of: day)
        let lastMonthEnd = try #require(monthStart.adding(days: -1))
        let isRaise = current.map { limit > $0 } ?? false
        if isRaise, staging.value(on: lastMonthEnd) != current {
          #expect(throws: FinanceError.limitChangedThisMonth, "a raise after this month's limit changed") { try staging.monthlyLimit(to: limit, today: day) }
          continue
        }
        let next = try staging.monthlyLimit(to: limit, today: day)
        #expect(next.value(on: lastMonthEnd) == staging.value(on: lastMonthEnd), "last month keeps its limit")
        #expect(next.latest(on: day) == limit)
        #expect(next.value(on: nextMonth) == limit)
        if isRaise {
          #expect(next.value(on: day) == current, "a raise waits for the next month")
          #expect(next.pending(on: day) == StagedAmount(amountMinor: limit, from: nextMonth))
        } else {
          #expect(next.value(on: monthStart) == limit, "a lowering or a return to the limit in force holds for the whole month")
          #expect(next.pending(on: day) == nil)
        }
        staging = next
      }
    }
  }

  @Test func shouldStageEveryOneOffEditAsTheRulesSay() throws {
    try forAll(iterations: 300) { generator in
      var staging = BudgetStaging(base: generator.chance(0.5) ? Int64(generator.int(in: 0...10_000)) : nil, staged: nil)
      var day = Self.firstDay
      for _ in 0..<generator.int(in: 1...12) {
        day = day.adding(days: generator.int(in: 0...40)) ?? day
        let threshold = generator.chance(0.2) ? nil : Int64(generator.int(in: 0...10_000))
        let next = try staging.oneOff(to: threshold, today: day)
        let current = staging.value(on: day)
        switch (threshold, current) {
        case (nil, _):
          #expect(next == BudgetStaging(base: nil, staged: nil))
        case (let threshold?, let current?) where threshold >= current:
          #expect(next == BudgetStaging(base: threshold, staged: nil), "a higher threshold applies at once")
        case (let threshold?, _):
          #expect(next.value(on: day) == current, "a lower threshold waits for the next month")
          #expect(next.value(on: try BudgetStaging.nextMonthStart(of: day)) == threshold)
        }
        staging = next
      }
    }
  }

  @Test func shouldKeepAnotherDevicesHomeLimitThroughALaggingDevicesEnsure() async throws {
    try await forAll(iterations: 12) { generator in
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry, seed: generator.next()))
      _ = try await replicas.write(0) { transaction in try FinanceFixture.settings(home: F.eur, budgetMinor: 50_000).create(in: &transaction) }
      try await replicas.settle()
      _ = try await replicas.write(0) { transaction in
        try BudgetEdits.update(HomeBudget.id, today: F.date("2026-10-15"), in: &transaction) { $0.limitMinor = 40_000 }
        try BudgetEdits.update(HomeBudget.id, today: Self.today, in: &transaction) { $0.limitMinor = 30_000 }
        try BudgetEdits.update(HomeBudget.id, today: Self.today, in: &transaction) { $0.oneOffFromMinor = 9_000 }
      }
      await replicas.advanceClock(of: 1, by: .seconds(Int64(generator.int(in: 1...5))))
      let lagging = try await replicas.write(1) { transaction in try HomeBudget.ensure(on: F.date("2026-11-25"), in: &transaction) }
      #expect(lagging == .created(BudgetRecord(id: HomeBudget.id, currency: F.eur, period: .monthly, createdOn: F.date("2026-11-25"))))
      while try await replicas.step(using: &generator) {}
      try await replicas.settle()
      for index in 0..<2 {
        let home = try #require(try await F.budgets(in: replicas.store(index)).home)
        #expect(home.record.createdOn == F.date("2026-10-15"), "the first device's creation day stays")
        #expect(home.record.limitMinor == 40_000, "the lagging ensure wrote no limit that could undo the other device's")
        #expect(home.limitMinor(on: Self.today) == 30_000)
        #expect(home.limitMinor(on: F.date("2026-10-31")) == 40_000)
        #expect(home.limitMinor(on: F.date("2026-09-30")) == 40_000, "a written limit no longer falls back to the account's")
        #expect(home.pendingOneOff(on: Self.today)?.amountMinor == 9_000)
      }
    }
  }

  @Test func shouldAgreeOnEveryAssignmentWhenTwoDevicesCreateBudgetsThatCollide() async throws {
    let category = try MemoirStoreFixture.category("food")
    try await forAll(iterations: 12) { generator in
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry, seed: generator.next()))
      _ = try await replicas.write(0) { transaction in
        try FinanceFixture.settings(home: F.eur).create(in: &transaction)
        for (number, date) in [(1, "2026-12-12"), (2, "2026-12-18"), (3, "2026-12-24"), (4, "2026-11-30")] {
          try ExpenseRecord(id: FinanceFixture.expenseID(number), amountMinor: 1, currency: F.usd, occurredOn: F.date(date), category: category, loggedAtMillis: 1)
            .create(in: &transaction)
        }
      }
      try await replicas.settle()
      let drafts = [
        [F.trip("Lisbon", F.eur, limitMinor: 1, from: "2026-12-10", through: "2026-12-20"), F.monthly("Dollars", F.usd, limitMinor: 1)],
        [F.trip("Porto", F.eur, limitMinor: 1, from: "2026-12-15", through: "2026-12-25"), F.monthly("Also dollars", F.usd, limitMinor: 1)],
      ]
      for index in 0..<2 {
        await replicas.advanceClock(of: index, by: .milliseconds(Int64(generator.int(in: 0...5))))
        let created = F.date(index == 0 ? "2026-11-20" : "2026-11-21")
        _ = try await replicas.write(index) { transaction in
          for (offset, draft) in drafts[index].enumerated() { try BudgetEdits.create(draft, id: F.id(index * 10 + offset), today: created, in: &transaction) }
        }
      }
      while try await replicas.step(using: &generator) {}
      try await replicas.settle()
      let first = try await replicas.store(0).read { transaction in try BudgetAssignments.load(from: transaction) }
      let second = try await replicas.store(1).read { transaction in try BudgetAssignments.load(from: transaction) }
      #expect(first == second)
      #expect(first.budgets.live.count == 5)
      #expect(first.assignments[FinanceFixture.expenseID(1)]?.budget == F.id(0))
      #expect(first.assignments[FinanceFixture.expenseID(2)]?.budget == F.id(0), "the trip created first takes the days both hold")
      #expect(first.assignments[FinanceFixture.expenseID(3)]?.budget == F.id(10))
      #expect(first.assignments[FinanceFixture.expenseID(4)]?.budget == F.id(1), "the monthly budget created first takes the currency")
    }
  }
}
