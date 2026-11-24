import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Expense refunds", TestTimeLimit.standard)
struct ExpenseRefundTests {
  private static let id = MoneyReadsFixture.id(1)

  private static func issuer(hour: Int = 12) -> CommandIssuer {
    MoneyReadsFixture.issuer(on: MoneyReadsFixture.date("2026-11-21"), hour: hour)
  }

  private static func stores(amountMinor: Int64 = 2_000, fromSavingsMinor: Int64? = nil) async throws -> MemoirStores {
    let stores = try MemoirStores.openInMemory()
    var expense = MoneyReadsFixture.expense(1, amountMinor, "EUR", on: "2026-11-20", merchant: "Café", note: "Lunch")
    expense.fromSavingsMinor = fromSavingsMinor
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings(), expense])
    return stores
  }

  private static func refund(_ amount: RefundAmount, in stores: MemoirStores, hour: Int = 12) async throws {
    _ = try await stores.main.write { transaction in try ExpenseEdits.refund(id, amount: amount, issuer: issuer(hour: hour), in: &transaction) }
  }

  private static func refusal(
    in stores: MemoirStores, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void
  ) async -> CommandIssueError? {
    do {
      try await stores.main.write { transaction in try body(&transaction) }
      return nil
    } catch {
      guard case .aborted(let inner as CommandIssueError) = error else { return nil }
      return inner
    }
  }

  private static func refusal(_ amount: RefundAmount, in stores: MemoirStores) async -> CommandIssueError? {
    await refusal(in: stores) { transaction in try ExpenseEdits.refund(id, amount: amount, issuer: issuer(), in: &transaction) }
  }

  private static func expense(in stores: MemoirStores) async throws -> ExpenseRecord {
    try #require(try await stores.main.read { transaction in try ExpenseRecord.read(id: id, in: transaction) }.entry?.record)
  }

  @Test func shouldMoveTheAmountToZeroOnAFullRefundAndKeepTheRecord() async throws {
    let stores = try await Self.stores()
    try await Self.refund(.full, in: stores)
    let expense = try await Self.expense(in: stores)
    #expect(expense.amountMinor == 0)
    #expect(expense.note == "Lunch" && expense.merchant == "Café", "a refund keeps the record's words")
    let history = try await MoneyReads.history(of: Self.id, in: stores)
    #expect(history.entries.map(\.action) == [.refunded(from: 2_000, to: 0, changes: [.amount(from: 2_000, to: 0)])])
  }

  @Test func shouldTakeThePartialAmountOffAndRefundTheRestLater() async throws {
    let stores = try await Self.stores()
    try await Self.refund(.partial(500), in: stores, hour: 9)
    #expect(try await Self.expense(in: stores).amountMinor == 1_500)
    try await Self.refund(.partial(1_500), in: stores, hour: 10)
    #expect(try await Self.expense(in: stores).amountMinor == 0, "a partial refund of what is left is a full one")
    let history = try await MoneyReads.history(of: Self.id, in: stores)
    #expect(
      history.entries.map(\.action) == [
        .refunded(from: 1_500, to: 0, changes: [.amount(from: 1_500, to: 0)]), .refunded(from: 2_000, to: 1_500, changes: [.amount(from: 2_000, to: 1_500)]),
      ])
  }

  @Test func shouldRefuseEveryRefundThatCannotBeApplied() async throws {
    let stores = try await Self.stores()
    guard case .refused(.finance(.refundExceedsAmount(refund: 2_001, amount: 2_000)))? = await Self.refusal(.partial(2_001), in: stores) else {
      Issue.record("a refund above the amount is refused")
      return
    }
    guard case .refused(.finance(.refundNotPositive(0)))? = await Self.refusal(.partial(0), in: stores) else {
      Issue.record("a refund of zero is refused")
      return
    }
    guard case .refused(.finance(.refundNotPositive(-5)))? = await Self.refusal(.partial(-5), in: stores) else {
      Issue.record("a negative refund is refused")
      return
    }
    #expect(try await Self.expense(in: stores).amountMinor == 2_000, "a refusal writes nothing")
    #expect(try await MoneyReads.history(of: Self.id, in: stores).entries.isEmpty)

    try await Self.refund(.full, in: stores)
    for amount in [RefundAmount.full, .partial(1), .partial(0)] {
      guard case .refused(.finance(.nothingToRefund(Self.id)))? = await Self.refusal(amount, in: stores) else {
        Issue.record("\(amount) on a refunded expense is refused")
        return
      }
    }
    #expect(try await MoneyReads.history(of: Self.id, in: stores).entries.count == 1)
  }

  @Test func shouldRefuseARefundOfAnExpenseThatIsAbsentOrDeleted() async throws {
    let stores = try await Self.stores()
    let missing = await Self.refusal(in: stores) { transaction in
      try ExpenseEdits.refund(MoneyReadsFixture.id(9), amount: .full, issuer: Self.issuer(), in: &transaction)
    }
    guard case .record(.absent)? = missing else {
      Issue.record("an unknown expense is absent, not \(String(describing: missing))")
      return
    }
    _ = try await stores.main.write { transaction in try ExpenseEdits.delete(Self.id, issuer: Self.issuer(hour: 9), in: &transaction) }
    guard case .record(.absent)? = await Self.refusal(.full, in: stores) else {
      Issue.record("a deleted expense is absent to a refund")
      return
    }
  }

  @Test func shouldReturnWhatNoLongerFitsFromSavingsToSavings() async throws {
    let stores = try await Self.stores(amountMinor: 2_000, fromSavingsMinor: 1_500)
    try await Self.refund(.partial(300), in: stores, hour: 9)
    #expect(try await Self.expense(in: stores).fromSavingsMinor == 1_500, "a draw that still fits stays")
    try await Self.refund(.partial(500), in: stores, hour: 10)
    let clamped = try await Self.expense(in: stores)
    #expect(clamped.amountMinor == 1_200 && clamped.fromSavingsMinor == 1_200, "the draw never exceeds the amount")
    try await Self.refund(.full, in: stores, hour: 11)
    #expect(try await Self.expense(in: stores).fromSavingsMinor == nil, "a full refund draws nothing from savings")
    let history = try await MoneyReads.history(of: Self.id, in: stores)
    #expect(
      history.entries.first?.action == .refunded(from: 1_200, to: 0, changes: [.amount(from: 1_200, to: 0), .fromSavings(from: 1_200, to: nil)]))
    #expect(
      history.entries.last?.action == .refunded(from: 2_000, to: 1_700, changes: [.amount(from: 2_000, to: 1_700)]), "an edit that moves no draw records no draw")
  }

  @Test func shouldLeaveAnExpenseWithoutASavingsDrawWithoutOne() async throws {
    let stores = try await Self.stores()
    try await Self.refund(.partial(100), in: stores)
    #expect(try await Self.expense(in: stores).fromSavingsMinor == nil)
  }

  private static func state(of id: UUID, in stores: MemoirStores) async throws -> ExpenseRefundState? {
    let listing = try await MoneyReads.expenses(in: stores, matching: ExpenseQuery(span: nil))
    return try #require(listing.rows.items.first { $0.expense.id == id }).refund
  }

  @Test func shouldListFullAndPartialRefundsAndLeaveOtherExpensesUnmarked() async throws {
    let stores = try await Self.stores()
    let other = MoneyReadsFixture.id(2)
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.expense(2, 800, "EUR", on: "2026-11-19")])
    #expect(try await Self.state(of: Self.id, in: stores) == nil)
    #expect(try await Self.state(of: other, in: stores) == nil)
    try await Self.refund(.partial(500), in: stores, hour: 9)
    try await Self.refund(.partial(700), in: stores, hour: 10)
    #expect(try await Self.state(of: Self.id, in: stores) == .partial(refundedMinor: 1_200), "the total of the refunds")
    try await Self.refund(.full, in: stores, hour: 11)
    #expect(try await Self.state(of: Self.id, in: stores) == .full)
    #expect(try await Self.state(of: other, in: stores) == nil)
  }

  @Test func shouldNotListAZeroAmountExpenseThatWasNeverRefundedAsRefunded() async throws {
    let stores = try MemoirStores.openInMemory()
    let eur = try MemoirStoreFixture.currency("EUR")
    let anchor = try MemoirStoreFixture.date("2026-01-31")
    let trial = try FinanceFixture.subscription(frequency: .monthly, billingDay: 31, anchorOn: anchor, amountMinor: 0, currency: eur)
    let cycle = CycleConfirmation(subscription: trial.id, billingDate: anchor)
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings(), MoneyReadsFixture.expense(1, 0, "EUR", on: "2026-11-20"), trial])
    _ = try await stores.main.write { transaction in try SubscriptionCycles.confirm(cycle, loggedAtMillis: 1, in: &transaction) }
    let listing = try await MoneyReads.expenses(in: stores, matching: ExpenseQuery(span: nil))
    #expect(listing.rows.items.count == 2 && listing.rows.items.allSatisfy { $0.refund == nil && $0.expense.amountMinor == 0 })
    guard case .refused(.finance(.nothingToRefund(Self.id)))? = await Self.refusal(.full, in: stores) else {
      Issue.record("a zero-amount expense has nothing to refund")
      return
    }
  }

  @Test func shouldDropTheRefundStateWhenALaterEditMovesTheAmountAgain() async throws {
    let stores = try await Self.stores()
    try await Self.refund(.partial(500), in: stores, hour: 9)
    _ = try await stores.main.write { transaction in try ExpenseEdits.update(Self.id, issuer: Self.issuer(hour: 10), in: &transaction) { $0.note = "Dinner" } }
    #expect(try await Self.state(of: Self.id, in: stores) == .partial(refundedMinor: 500), "an edit that leaves the amount alone keeps the refund")
    _ = try await stores.main.write { transaction in try ExpenseEdits.update(Self.id, issuer: Self.issuer(hour: 11), in: &transaction) { $0.amountMinor = 900 } }
    #expect(try await Self.state(of: Self.id, in: stores) == nil, "an amount the owner set is not a refund")
    try await Self.refund(.partial(100), in: stores, hour: 12)
    #expect(try await Self.state(of: Self.id, in: stores) == .partial(refundedMinor: 100), "only the refunds since the owner's edit count")
  }

  @Test func shouldListTheRefundAgainstTheAmountTheMergeKeepsWhenADeviceClockRunsBehind() async throws {
    let stores = try await Self.stores()
    _ = try await stores.main.write { transaction in try ExpenseEdits.update(Self.id, issuer: Self.issuer(hour: 12), in: &transaction) { $0.amountMinor = 900 } }
    try await Self.refund(.partial(100), in: stores, hour: 8)
    #expect(try await Self.expense(in: stores).amountMinor == 800)
    #expect(try await Self.state(of: Self.id, in: stores) == .partial(refundedMinor: 100))
  }

  @Test func shouldKeepNoChangeRecordOrHistoryOfARefundAfterTheExpenseIsDeleted() async throws {
    let stores = try await Self.stores()
    try await Self.refund(.partial(500), in: stores, hour: 9)
    _ = try await stores.main.write { transaction in try ExpenseEdits.delete(Self.id, issuer: Self.issuer(hour: 10), in: &transaction) }
    let changes = try await stores.main.read { transaction in try ExpenseChangeRecord.listing(in: transaction).entries.count }
    #expect(changes == 0, "the deletion purges the refund's change record")
    let history = try await MoneyReads.history(of: Self.id, in: stores)
    #expect(history.entries.map(\.action) == [.deleted, .updated(changes: nil)], "the refund's command stays but its amounts do not")
  }

  @Test func shouldShowTheRefundInTheHistoryOfAnotherReplica() async throws {
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry, seed: 7))
    let issuer = CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock())
    _ = try await replicas.write(0) { transaction in
      try MoneyReadsFixture.settings().create(in: &transaction)
      try MoneyReadsFixture.expense(1, 2_000, "EUR", on: "2026-11-20").create(in: &transaction)
    }
    try await replicas.settle()
    _ = try await replicas.write(0) { transaction in try ExpenseEdits.refund(Self.id, amount: .partial(750), issuer: issuer, in: &transaction) }
    try await replicas.settle()
    let history = try await replicas.store(1).read { transaction in try ExpenseHistory.read(Self.id, in: transaction) }
    #expect(history.entries.map(\.action) == [.refunded(from: 2_000, to: 1_250, changes: [.amount(from: 2_000, to: 1_250)])])
    #expect(history.expense.entry?.record.amountMinor == 1_250)
  }

  @Test func shouldKeepARefundOfACycleExpenseWhenLaggingDevicesConfirmTheCycleLater() async throws {
    let eur = try MemoirStoreFixture.currency("EUR")
    let anchor = try MemoirStoreFixture.date("2026-01-31")
    let subscription = try FinanceFixture.subscription(frequency: .monthly, billingDay: 31, anchorOn: anchor, amountMinor: 1_999, currency: eur)
    let cycle = CycleConfirmation(subscription: subscription.id, billingDate: anchor)
    let id = SubscriptionCycles.expenseID(for: cycle)
    let issuer = CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock())
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 3, registry: MemoirSchema.mainRegistry, seed: 11))
    _ = try await replicas.write(0) { transaction in
      try FinanceFixture.settings(home: eur).create(in: &transaction)
      try subscription.create(in: &transaction)
    }
    try await replicas.settle()
    _ = try await replicas.write(0) { transaction in
      _ = try #require(try SubscriptionCycles.confirm(cycle, loggedAtMillis: 1, in: &transaction))
      try ExpenseEdits.refund(id, amount: .partial(500), issuer: issuer, in: &transaction)
    }
    for lagging in 1..<3 {
      await replicas.advanceClock(of: lagging, by: .milliseconds(1_000 * lagging))
      _ = try await replicas.write(lagging) { transaction in try SubscriptionCycles.confirm(cycle, loggedAtMillis: Int64(1 + lagging), in: &transaction) }
    }
    try await replicas.settle()
    for index in 0..<3 {
      let history = try await replicas.store(index).read { transaction in try ExpenseHistory.read(id, in: transaction) }
      #expect(history.expense.entry?.record.amountMinor == 1_499, "replica \(index) keeps the refunded amount")
      #expect(history.entries.map(\.action).contains(.refunded(from: 1_999, to: 1_499, changes: [.amount(from: 1_999, to: 1_499)])), "replica \(index) keeps the refund's history")
    }
  }
}
