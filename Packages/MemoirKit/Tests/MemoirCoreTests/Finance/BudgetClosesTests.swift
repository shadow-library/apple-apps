import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Budget closes", TestTimeLimit.standard)
struct BudgetClosesTests {
  private typealias F = BudgetStandingsFixture

  private static let october = MoneyReadsFixture.date("2026-10-01")
  private static let key = MoneyCloseKey(budget: HomeBudget.id, periodStart: october)
  private static let now = Date(timeIntervalSince1970: TimeInterval(MoneyReadsFixture.millis(F.today)) / 1000)
  private static let horizon = MoneyReadsFixture.stamp(F.today, hour: 23)
  private static let usd = F.monthly(1, F.usd, limitMinor: 50_000, createdOn: "2026-07-01")

  /// Home from July with a 60 000 typical month, a dollar budget with ten dollars spent in October, 20 covered days of October and 50 000 spent at home
  /// in it: Home's October closes within its typical month and deposits 16 000.
  private static func seed() throws -> (records: [any MemoirRecord], commands: [MemoirCommand]) {
    var settings = MoneyReadsFixture.settings()
    settings.moneyScoredFrom = october
    let records: [any MemoirRecord] = [
      settings, F.home(createdOn: "2026-07-01"), usd, F.expense(101, 50_000, on: "2026-07-10"), F.expense(102, 60_000, on: "2026-08-10"),
      F.expense(103, 70_000, on: "2026-09-10"), F.expense(1, 50_000, on: "2026-10-05"), F.expense(2, 1_000, F.usd, on: "2026-10-07"),
    ]
    let commands = try (1...20).map { day in
      let date = try #require(october.adding(days: day - 1))
      return try ProjectionSupport.command(
        MemoirStoreFixture.commandID(500 + day), .moneyNoSpend(NoSpendDay(date: date)), at: MoneyReadsFixture.stamp(date), rulesetVersion: Ruleset.v2.version)
    }
    return (records, commands)
  }

  private static func stores() async throws -> MemoirStores {
    let stores = try MemoirStores.openInMemory(projection: try MemoirReconciler(appVersion: "1", horizon: { horizon }))
    let seed = try seed()
    try await MoneyReadsFixture.seed(stores.main, seed.records)
    try await ProjectionSupport.append(seed.commands, to: stores.main)
    return stores
  }

  private static func closable(in store: VaultStore, budget: UUID = HomeBudget.id) async throws -> ClosablePeriod {
    let periods = try await store.read { transaction in try BudgetCloseReads.closable(in: transaction, today: F.today, now: now) }
    return try #require(periods.first { $0.key == MoneyCloseKey(budget: budget, periodStart: october) })
  }

  private static func close(_ period: ClosablePeriod, in store: VaultStore, hour: Int = 12) async throws -> BudgetCloseWrite {
    try await store.write { transaction in try BudgetCloses.close(period, issuer: MoneyReadsFixture.issuer(on: F.today, hour: hour), in: &transaction) }
  }

  private static func deposit(in store: VaultStore, key: MoneyCloseKey = key) async throws -> SavingsDeposit? {
    try await store.read { transaction in
      try SavingsDepositRecord.read(key: .savingsDeposit(budget: key.budget, periodStart: key.periodStart), in: transaction).entry?.record.deposit
    }
  }

  private static func replayClose(in store: VaultStore) async throws -> MoneyClose? {
    try await store.read { transaction in try MemoirDerived.moneyClose(key, in: transaction)?.close }
  }

  private static func commandCount(in store: VaultStore) async throws -> Int {
    try await store.read { transaction in try transaction.states(ofKind: MemoirKind.command.entityKind, scope: .vault).count }
  }

  @Test func shouldIssueTheCloseAndWriteItsDepositInOneWrite() async throws {
    let stores = try await Self.stores()
    let period = try await Self.closable(in: stores.main)
    #expect(period.outcome == .withinTypical && period.deposit == .amount(16_000, rate: nil) && period.coverage.coveredDays == 20)

    guard case .closed(let command, let deposit) = try await Self.close(period, in: stores.main) else { throw MemoirFixtureError(description: "the period closes") }
    #expect(deposit == period.snapshot(command: command.id))
    #expect(try await Self.deposit(in: stores.main) == deposit)
    let replayed = try #require(try await Self.replayClose(in: stores.main))
    #expect(replayed.command == command.id && replayed.outcome == .withinTypical && replayed.deposited)
    #expect(
      try await stores.main.read { transaction in try BudgetCloseReads.closable(in: transaction, today: F.today, now: Self.now) }.map(\.key) == [
        MoneyCloseKey(budget: Self.usd.id, periodStart: Self.october)
      ])

    let standings = try #require(try await MoneyReads.budgetStandings(in: stores, today: F.today))
    #expect(standings.homeBudget?.history?.months.last?.source == .closeSnapshot(deposit))
    #expect(try await SavingsReads.overview(in: stores, today: F.today)?.balance.depositedMinor == 16_000)
    #expect(try await Self.close(period, in: stores.main) == .alreadyClosed, "a second close writes nothing")
  }

  @Test func shouldIssueOnlyTheCloseWhenAnotherDevicesDepositArrivedFirst() async throws {
    let stores = try await Self.stores()
    let period = try await Self.closable(in: stores.main)
    let theirs = SavingsDeposit(
      amountMinor: 4_000, currency: F.eur, closedOn: MoneyReadsFixture.date("2026-11-20"), command: MemoirStoreFixture.commandID(9), spentMinor: 62_000,
      limitMinor: 100_000, medianExpenseMinor: 31_000)
    try await MoneyReadsFixture.seed(stores.main, [SavingsDepositRecord(budget: HomeBudget.id, periodStart: Self.october, deposit: theirs)])
    let before = try await Self.commandCount(in: stores.main)

    guard case .closed(let command, let deposit) = try await Self.close(period, in: stores.main) else { throw MemoirFixtureError(description: "the period closes") }
    #expect(deposit == theirs && command.id != theirs.command)
    #expect(try await Self.deposit(in: stores.main) == theirs, "the deposit record is never overwritten")
    #expect(try await Self.commandCount(in: stores.main) == before + 1)
    let replayed = try #require(try await Self.replayClose(in: stores.main))
    #expect(replayed.outcome == .within && replayed.deposited, "judged from the record's frozen 62 000, above the typical month")
  }

  @Test func shouldWriteNothingWhenReplayClosedThePeriodMeanwhile() async throws {
    let stores = try await Self.stores()
    let period = try await Self.closable(in: stores.main)
    let theirs = try ProjectionSupport.command(
      MemoirStoreFixture.commandID(9),
      .budgetClosePeriod(try BudgetPeriodClose(budgetId: HomeBudget.id, periodStart: Self.october, outcome: .within, deposited: false)),
      at: MoneyReadsFixture.stamp(MoneyReadsFixture.date("2026-11-20")), rulesetVersion: Ruleset.v2.version)
    try await ProjectionSupport.append([theirs], to: stores.main)
    let before = try await Self.commandCount(in: stores.main)

    #expect(try await Self.close(period, in: stores.main) == .alreadyClosed)
    #expect(try await Self.commandCount(in: stores.main) == before)
    #expect(try await Self.deposit(in: stores.main) == nil)
  }

  @Test func shouldWriteNothingWhenThePeriodNoLongerCloses() async throws {
    let stores = try await Self.stores()
    let period = try await Self.closable(in: stores.main, budget: Self.usd.id)
    try await MoneyReadsFixture.write(stores.main) { transaction in _ = try BudgetRecord.remove(BudgetRecord.ref(Self.usd.id), in: &transaction) }
    let before = try await Self.commandCount(in: stores.main)

    #expect(try await Self.close(period, in: stores.main) == .notClosable)
    #expect(try await Self.commandCount(in: stores.main) == before)
    #expect(try await Self.deposit(in: stores.main, key: period.key) == nil)
  }

  @Test func shouldCloseNothingAndGrowNoCommandsWhileReplayIsHalted() async throws {
    let stores = try await Self.stores()
    let period = try await Self.closable(in: stores.main)
    try await MoneyReadsFixture.write(stores.main) { transaction in
      let future = try MemoirCommand(
        id: MemoirStoreFixture.commandID(99), payload: try CommandPayload(type: try CommandType("future.feature")),
        instantMillis: MoneyReadsFixture.millis(MoneyReadsFixture.date("2026-10-02")), utcOffsetMinutes: 0, issuedOn: MoneyReadsFixture.date("2026-10-02"),
        rulesetVersion: Ruleset.v2.version)
      try future.append(in: &transaction)
    }
    #expect(try await stores.main.read { transaction in try MemoirDerived.hero(in: transaction) }?.needsAppUpdate == true)
    let before = try await Self.commandCount(in: stores.main)

    for _ in 0..<3 {
      #expect(try await stores.main.read { transaction in try BudgetCloseReads.closable(in: transaction, today: F.today, now: Self.now) }.isEmpty)
      #expect(try await Self.close(period, in: stores.main) == .replayHalted)
    }
    #expect(try await Self.commandCount(in: stores.main) == before)
    #expect(try await Self.deposit(in: stores.main) == nil)
  }

  @Test func shouldKeepOneCloseAndOneDepositWhenTwoDevicesCloseTheSamePeriod() async throws {
    let reconcilers = try (0..<2).map { _ in try MemoirReconciler(appVersion: "1", horizon: { Self.horizon }) }
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry, reconciler: { reconcilers[$0] }))
    let seed = try Self.seed()
    _ = try await replicas.write(0) { transaction in
      for record in seed.records { try record.create(in: &transaction) }
      for command in seed.commands { try command.append(in: &transaction) }
    }
    try await replicas.settle()

    var issued = [MemoirCommand]()
    for index in 0..<2 {
      let store = await replicas.store(index)
      let period = try await Self.closable(in: store)
      await replicas.advanceClock(of: index, by: .seconds(index + 1))
      let written = try await replicas.write(index) { transaction in
        try BudgetCloses.close(period, issuer: MoneyReadsFixture.issuer(on: F.today, hour: 14 - index), in: &transaction)
      }
      guard case .closed(let command, _) = written else { throw MemoirFixtureError(description: "each device closes while offline") }
      issued.append(command)
    }
    try await replicas.settle()

    let first = try #require(try await Self.deposit(in: replicas.store(0)))
    let close = try #require(try await Self.replayClose(in: replicas.store(0)))
    #expect(Set(issued.map(\.id)).contains(first.command), "the deposit names the close it was written with")
    #expect(Set(issued.map(\.id)).contains(close.command))
    #expect(first.amountMinor == 16_000)
    for index in 0..<2 {
      let store = await replicas.store(index)
      #expect(try await Self.deposit(in: store) == first, "one first-writer deposit on every device")
      #expect(try await Self.replayClose(in: store) == close, "one replay close on every device")
      let outcomes = Replay.run(try await ProjectionSupport.commands(in: store), through: Self.horizon).outcomes
      #expect(issued.map { outcomes[$0.id] }.sorted { $0 == .applied && $1 != .applied } == [.applied, .superseded])
      #expect(try await store.read { transaction in try BudgetCloseReads.closable(in: transaction, today: F.today, now: Self.now) }.allSatisfy { $0.key != Self.key })
      let savings = try await store.read { transaction in try SavingsBook.load(from: transaction) }
      #expect(try SavingsFixture.overview(savings).balance.depositedMinor == 16_000, "savings count the one deposit")
    }
  }
}
