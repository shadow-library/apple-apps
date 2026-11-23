import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Finance convergence", TestTimeLimit.property)
struct FinanceConvergenceTests {
  private static let replicaCount = 3

  private struct Snapshot: Equatable {
    let rates: [FxRateRecord]
    let expenses: [ExpenseRecord]
    let removed: Int
  }

  private static func snapshot(_ store: VaultStore) async throws -> Snapshot {
    try await store.read { transaction in
      let expenses = try ExpenseRecord.listing(in: transaction)
      return Snapshot(
        rates: try FxRateRecord.listing(in: transaction).entries.map(\.record), expenses: expenses.entries.filter { !$0.isRemoved }.map(\.record),
        removed: expenses.entries.count(where: \.isRemoved))
    }
  }

  private static func deliverInSomeOrder(_ replicas: CausalReplicas, using generator: inout SeededGenerator) async throws {
    while try await replicas.step(using: &generator) {}
    try await replicas.settle()
  }

  private static func flush(_ replicas: CausalReplicas, _ index: Int) async throws {
    _ = try await replicas.write(index) { _ in }
  }

  @Test func shouldAgreeOnOneRatePerPairAndDayWhenEveryDeviceFillsAtOnce() async throws {
    let eur = try MemoirStoreFixture.currency("EUR")
    let jpy = try MemoirStoreFixture.currency("JPY")
    let usd = try MemoirStoreFixture.currency("USD")
    let day = try MemoirStoreFixture.date("2026-11-10")
    try await forAll(iterations: 12) { generator in
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: Self.replicaCount, registry: MemoirSchema.mainRegistry, seed: generator.next()))
      _ = try await replicas.write(0) { transaction in
        try FinanceFixture.settings(home: eur, budgetMinor: 50_000).create(in: &transaction)
        try FinanceFixture.expense(1, amountMinor: 1_200, currency: jpy, on: day).create(in: &transaction)
        try FinanceFixture.expense(2, amountMinor: 999, currency: usd, on: day).create(in: &transaction)
      }
      try await replicas.settle()
      for index in 0..<Self.replicaCount {
        let yenRate = try MemoirStoreFixture.decimal("0.006\(index + 1)")
        let dollarRate = try MemoirStoreFixture.decimal("0.9\(index + 1)")
        let client = ScriptedRatesClient([day: [CurrencyPair(base: jpy, quote: eur): yenRate, CurrencyPair(base: usd, quote: eur): dollarRate]])
        await replicas.advanceClock(of: index, by: .milliseconds(Int(generator.int(in: 0...5))))
        let report = try await RateFiller(client: client).fill(replicas.store(index), today: FinanceFixture.today)
        #expect(report.filledExpenses == 2)
        try await Self.flush(replicas, index)
      }
      try await Self.deliverInSomeOrder(replicas, using: &generator)
      let first = try await Self.snapshot(replicas.store(0))
      #expect(first.rates.count == 2)
      for index in 1..<Self.replicaCount { #expect(try await Self.snapshot(replicas.store(index)) == first) }
      let converter = HomeConverter(home: eur, rates: first.rates)
      for expense in first.expenses {
        let recorded = try #require(first.rates.first { $0.base == expense.currency })
        let expected = try HomeConversion.convert(MoneyAmount(amountMinor: expense.amountMinor, currency: expense.currency), to: eur, at: ExchangeRate(recorded.rate))
        #expect(converter.homeAmount(of: expense) == .converted(expected.amountMinor), "every expense converts at the first record of its pair and day")
      }
      let standings = try await (0..<Self.replicaCount).asyncMap { index in try await FinanceFixture.ledger(in: replicas.store(index)).budgetStanding(today: day) }
      #expect(Set(standings).count == 1)
    }
  }

  @Test func shouldConvertAnExpenseLockedFromTheLosingRateAtTheWinningRate() async throws {
    let eur = try MemoirStoreFixture.currency("EUR")
    let usd = try MemoirStoreFixture.currency("USD")
    let day = try MemoirStoreFixture.date("2026-11-10")
    let pair = CurrencyPair(base: usd, quote: eur)
    let winning = try MemoirStoreFixture.decimal("0.9")
    let losing = try MemoirStoreFixture.decimal("0.95")
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry))
    _ = try await replicas.write(0) { transaction in
      try FinanceFixture.settings(home: eur).create(in: &transaction)
      try FinanceFixture.expense(1, amountMinor: 999, currency: usd, on: day).create(in: &transaction)
    }
    try await replicas.settle()
    _ = try await RateFiller(client: ScriptedRatesClient([day: [pair: winning]])).fill(replicas.store(0), today: FinanceFixture.today)
    try await Self.flush(replicas, 0)
    await replicas.advanceClock(of: 1, by: .seconds(1))
    _ = try await RateFiller(client: ScriptedRatesClient([day: [pair: losing]])).fill(replicas.store(1), today: FinanceFixture.today)
    let captured = try await replicas.write(1) { transaction in
      try FinanceFixture.expense(2, amountMinor: 4_250, currency: usd, on: day).createCapturingRate(in: &transaction)
    }
    #expect(captured.rate?.rate == losing)
    try await replicas.settle()
    for index in 0..<2 {
      let ledger = try await FinanceFixture.ledger(in: replicas.store(index))
      #expect(ledger.rates.map(\.rate) == [winning])
      #expect(ledger.expenses.map { $0.rate?.rate } == [winning, losing], "the second expense keeps the lock it took from the losing record")
      let converter = try #require(ledger.converter)
      #expect(ledger.expenses.map { converter.homeAmount(of: $0) } == [.converted(899), .converted(3_825)])
    }
  }

  @Test func shouldKeepTheOwnersRateWhenAnotherDeviceFillsTheSameExpenseMeanwhile() async throws {
    let eur = try MemoirStoreFixture.currency("EUR")
    let usd = try MemoirStoreFixture.currency("USD")
    let day = try MemoirStoreFixture.date("2026-11-10")
    let id = FinanceFixture.expenseID(1)
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry))
    _ = try await replicas.write(0) { transaction in
      try FinanceFixture.settings(home: eur).create(in: &transaction)
      try FinanceFixture.expense(1, amountMinor: 10_000, currency: usd, on: day).create(in: &transaction)
    }
    try await replicas.settle()
    let typed = ManualRate(rate: try MemoirStoreFixture.decimal("0.8"), quote: eur)
    _ = try await replicas.write(0) { transaction in try ExpenseRecord.edit(id: id, in: &transaction) { $0.manualRate = typed } }
    await replicas.advanceClock(of: 1, by: .seconds(1))
    let pair = CurrencyPair(base: usd, quote: eur)
    let report = try await RateFiller(client: ScriptedRatesClient([day: [pair: try MemoirStoreFixture.decimal("0.9")]])).fill(replicas.store(1), today: FinanceFixture.today)
    #expect(report.filledExpenses == 1, "the second device has not seen the owner's rate yet")
    try await Self.flush(replicas, 1)
    try await replicas.settle()
    let first = try await Self.snapshot(replicas.store(0))
    #expect(try await Self.snapshot(replicas.store(1)) == first)
    let expense = try #require(first.expenses.first)
    #expect(expense.manualRate?.rate == (try MemoirStoreFixture.decimal("0.8")))
    #expect(expense.rate?.rate == (try MemoirStoreFixture.decimal("0.9")))
    #expect(HomeConverter(home: eur, rates: first.rates).homeAmount(of: expense) == .converted(8_000), "every device converts at the owner's rate")
  }

  @Test func shouldLetALaterConfirmationElsewhereRestoreAndRevertTheCycleExpense() async throws {
    let eur = try MemoirStoreFixture.currency("EUR")
    let anchor = try MemoirStoreFixture.date("2026-01-31")
    let subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 31, anchorOn: anchor, amountMinor: 1_999, currency: eur)
    let cycle = CycleConfirmation(subscription: subscription.id, billingDate: anchor)
    for deletes in [true, false] {
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry))
      _ = try await replicas.write(0) { transaction in
        try FinanceFixture.settings(home: eur).create(in: &transaction)
        try subscription.create(in: &transaction)
      }
      try await replicas.settle()
      _ = try await replicas.write(0) { transaction in
        let expense = try #require(try SubscriptionCycles.confirm(cycle, loggedAtMillis: 1, in: &transaction))
        if deletes {
          try ExpenseRecord.remove(expense.ref, in: &transaction)
        } else {
          try ExpenseRecord.edit(id: expense.id, in: &transaction) { $0.amountMinor = 2_500 }
        }
      }
      await replicas.advanceClock(of: 1, by: .seconds(1))
      let rewritten = try await replicas.write(1) { transaction in try SubscriptionCycles.confirm(cycle, loggedAtMillis: 2, in: &transaction) }
      #expect(rewritten != nil, "the second device has not received the expense, so it writes it again")
      try await replicas.settle()
      for index in 0..<2 {
        let snapshot = try await Self.snapshot(replicas.store(index))
        #expect(snapshot.removed == 0, "a later confirmation elsewhere restores the expense the owner deleted")
        #expect(snapshot.expenses.map(\.amountMinor) == [1_999], "and reverts the owner's edit")
        #expect(snapshot.expenses.map(\.loggedAtMillis) == [1], "the first writer's logging time stays")
      }
    }
  }

  @Test func shouldWriteOneExpenseWhenTwoDevicesConfirmTheSameCycle() async throws {
    let eur = try MemoirStoreFixture.currency("EUR")
    let anchor = try MemoirStoreFixture.date("2026-01-31")
    let subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 31, anchorOn: anchor, amountMinor: 1_999, currency: eur)
    try await forAll(iterations: 12) { generator in
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: Self.replicaCount, registry: MemoirSchema.mainRegistry, seed: generator.next()))
      _ = try await replicas.write(0) { transaction in
        try FinanceFixture.settings(home: eur).create(in: &transaction)
        try subscription.create(in: &transaction)
      }
      try await replicas.settle()
      let cycles = [anchor, try MemoirStoreFixture.date("2026-02-28")].map { CycleConfirmation(subscription: subscription.id, billingDate: $0) }
      var written = 0
      for index in 0..<Self.replicaCount {
        await replicas.advanceClock(of: index, by: .milliseconds(Int(generator.int(in: 0...5))))
        for cycle in cycles where index == 0 || generator.chance(0.7) {
          let expense = try await replicas.write(index) { transaction in try SubscriptionCycles.confirm(cycle, loggedAtMillis: Int64(index), in: &transaction) }
          if expense != nil { written += 1 }
        }
      }
      #expect(written >= cycles.count)
      try await Self.deliverInSomeOrder(replicas, using: &generator)
      let first = try await Self.snapshot(replicas.store(0))
      #expect(Set(first.expenses.map(\.id)) == Set(cycles.map(SubscriptionCycles.expenseID(for:))))
      for index in 1..<Self.replicaCount { #expect(try await Self.snapshot(replicas.store(index)) == first) }
      let late = try await replicas.write(1) { transaction in try SubscriptionCycles.confirm(cycles[0], loggedAtMillis: 99, in: &transaction) }
      #expect(late == nil)
      let schedule = try SubscriptionSchedule(subscription: subscription, confirmations: cycles.reversed())
      #expect(schedule.nextDue == (try MemoirStoreFixture.date("2026-03-31")))
    }
  }
}

extension Range where Bound == Int {
  fileprivate func asyncMap<T>(_ transform: (Int) async throws -> T) async rethrows -> [T] {
    var results = [T]()
    for index in self { results.append(try await transform(index)) }
    return results
  }
}
