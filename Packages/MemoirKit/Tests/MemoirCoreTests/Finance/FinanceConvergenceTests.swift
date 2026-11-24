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

  private enum OwnerAction: CaseIterable {
    case delete
    case raise
    case refund
    case renote
  }

  @Test func shouldKeepTheOwnersDeletionOrEditWhenLaggingDevicesConfirmTheCycleLater() async throws {
    let eur = try MemoirStoreFixture.currency("EUR")
    let anchor = try MemoirStoreFixture.date("2026-01-31")
    let subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 31, anchorOn: anchor, amountMinor: 1_999, currency: eur)
    let cycle = CycleConfirmation(subscription: subscription.id, billingDate: anchor)
    let id = SubscriptionCycles.expenseID(for: cycle)
    let issuer = CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock())
    try await forAll(iterations: 16) { generator in
      let action = OwnerAction.allCases[generator.int(in: 0...(OwnerAction.allCases.count - 1))]
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: Self.replicaCount, registry: MemoirSchema.mainRegistry, seed: generator.next()))
      _ = try await replicas.write(0) { transaction in
        try FinanceFixture.settings(home: eur).create(in: &transaction)
        try subscription.create(in: &transaction)
      }
      try await replicas.settle()
      _ = try await replicas.write(0) { transaction in
        _ = try #require(try SubscriptionCycles.confirm(cycle, loggedAtMillis: 1, in: &transaction))
        switch action {
        case .delete:
          _ = try ExpenseEdits.update(id, issuer: issuer, in: &transaction) { $0.note = "Annual" }
          _ = try ExpenseEdits.delete(id, issuer: issuer, in: &transaction)
        case .raise: _ = try ExpenseEdits.update(id, issuer: issuer, in: &transaction) { $0.amountMinor = 2_500 }
        case .refund: _ = try ExpenseEdits.update(id, issuer: issuer, in: &transaction) { $0.amountMinor = 499 }
        case .renote: _ = try ExpenseEdits.update(id, issuer: issuer, in: &transaction) { $0.note = "Annual" }
        }
      }
      for lagging in 1..<Self.replicaCount {
        await replicas.advanceClock(of: lagging, by: .milliseconds(Int(generator.int(in: 1...5_000))))
        let rewritten = try await replicas.write(lagging) { transaction in try SubscriptionCycles.confirm(cycle, loggedAtMillis: Int64(1 + lagging), in: &transaction) }
        #expect(rewritten?.cycle?.subscription == subscription.id, "a device that has not received the expense writes its seed, later than the owner's change")
      }
      try await Self.deliverInSomeOrder(replicas, using: &generator)
      let first = try await Self.snapshot(replicas.store(0))
      for index in 1..<Self.replicaCount { #expect(try await Self.snapshot(replicas.store(index)) == first) }
      let history = try await (0..<Self.replicaCount).asyncMap { index in
        try await replicas.store(index).read { transaction in try ExpenseChangeRecord.listing(in: transaction).entries.count }
      }
      switch action {
      case .delete:
        #expect(first.removed == 1 && first.expenses.isEmpty, "the deletion stays")
        #expect(history == Array(repeating: 0, count: Self.replicaCount))
        for index in 0..<Self.replicaCount {
          #expect(try await FinanceFixture.heldWords(["Annual", "Plan"], in: replicas.store(index)).isEmpty, "no replica keeps the owner's words")
        }
      case .raise, .refund, .renote:
        let expected: (amount: Int64, note: String?) =
          switch action {
          case .raise: (2_500, nil)
          case .refund: (499, nil)
          default: (1_999, "Annual")
          }
        #expect(first.removed == 0)
        #expect(first.expenses.map(\.amountMinor) == [expected.amount] && first.expenses.map(\.note) == [expected.note], "the owner's edit stays")
        #expect(first.expenses.map(\.loggedAtMillis) == [1], "the first writer's logging time stays")
        #expect(history == Array(repeating: 1, count: Self.replicaCount), "no device drops the owner's history")
      }
    }
  }

  @Test func shouldSettleOnTheEarlierSeedWhenTwoDevicesConfirmACycleFromDifferentSubscriptions() async throws {
    let eur = try MemoirStoreFixture.currency("EUR")
    let anchor = try MemoirStoreFixture.date("2026-01-31")
    let subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 31, anchorOn: anchor, amountMinor: 1_999, currency: eur)
    let cycle = CycleConfirmation(subscription: subscription.id, billingDate: anchor)
    try await forAll(iterations: 12) { generator in
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry, seed: generator.next()))
      _ = try await replicas.write(0) { transaction in
        try FinanceFixture.settings(home: eur).create(in: &transaction)
        try subscription.create(in: &transaction)
      }
      try await replicas.settle()
      _ = try await replicas.write(1) { transaction in
        try SubscriptionRecord.edit(id: subscription.id, in: &transaction) { $0.amountMinor = 2_999 }
      }
      let earlier = generator.int(in: 0...1)
      await replicas.advanceClock(of: 1 - earlier, by: .milliseconds(Int(generator.int(in: 1...5_000))))
      for index in [earlier, 1 - earlier] {
        _ = try await replicas.write(index) { transaction in try SubscriptionCycles.confirm(cycle, loggedAtMillis: Int64(10 + index), in: &transaction) }
      }
      try await Self.deliverInSomeOrder(replicas, using: &generator)
      let first = try await Self.snapshot(replicas.store(0))
      #expect(try await Self.snapshot(replicas.store(1)) == first)
      let seed: Int64 = earlier == 0 ? 1_999 : 2_999
      let expense = try #require(first.expenses.first)
      #expect(expense.cycle?.amountMinor == seed && expense.amountMinor == seed && expense.note == nil)
      #expect(expense.loggedAtMillis == Int64(10 + earlier), "the earlier confirmation's write wins every first-writer field")
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
