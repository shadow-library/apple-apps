import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Savings withdrawals", TestTimeLimit.standard)
struct SavingsWithdrawalTests {
  private typealias S = SavingsFixture

  /// Savings hold 30 000 and Home's limit lets them go 100 000 below zero; the typical single expense is 2 000, so a one-off is 20 000 or more.
  private static func stores(_ records: [any MemoirRecord] = []) async throws -> MemoirStores {
    let stores = try MemoirStores.openInMemory()
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings(budgetMinor: 100_000), S.home()] + S.steadyDeposits + records)
    return stores
  }

  private static var issuer: CommandIssuer { MoneyReadsFixture.issuer(on: S.today) }

  private static func create(_ expense: ExpenseRecord, in stores: MemoirStores) async throws {
    _ = try await stores.main.write { transaction in try ExpenseEdits.create(expense, issuer: issuer, in: &transaction) }
  }

  private static func refusal(creating expense: ExpenseRecord, in stores: MemoirStores) async -> FinanceError? {
    await refusal(in: stores) { transaction in _ = try ExpenseEdits.create(expense, issuer: issuer, in: &transaction) }
  }

  private static func refusal(updating number: Int, in stores: MemoirStores, _ change: @escaping @Sendable (inout ExpenseRecord) -> Void) async -> FinanceError? {
    await refusal(in: stores) { transaction in _ = try ExpenseEdits.update(MoneyReadsFixture.id(number), issuer: issuer, in: &transaction) { change(&$0) } }
  }

  private static func refusal(in stores: MemoirStores, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async -> FinanceError? {
    do {
      try await stores.main.write { transaction in try body(&transaction) }
      return nil
    } catch {
      guard case .aborted(CommandIssueError.refused(.finance(let inner))) = error else { return .store("unexpected \(error)") }
      return inner
    }
  }

  private static func balance(in stores: MemoirStores) async throws -> SavingsBalance {
    try #require(try await SavingsReads.overview(in: stores, today: S.today)).balance
  }

  @Test func shouldRefuseAPartFromSavingsThatIsNotAboveZeroOrIsAboveTheAmount() async throws {
    let stores = try await Self.stores()
    #expect(await Self.refusal(creating: S.expense(1, 30_000, on: "2026-11-20", fromSavingsMinor: 0), in: stores) == .savingsNotPositive(0))
    #expect(await Self.refusal(creating: S.expense(1, 30_000, on: "2026-11-20", fromSavingsMinor: -1), in: stores) == .savingsNotPositive(-1))
    #expect(
      await Self.refusal(creating: S.expense(1, 30_000, on: "2026-11-20", fromSavingsMinor: 30_001), in: stores)
        == .savingsExceedsAmount(savings: 30_001, amount: 30_000))
    #expect(try await Self.balance(in: stores).withdrawnMinor == 0)
  }

  @Test func shouldDrawOnlyForAOneOff() async throws {
    let stores = try await Self.stores()
    #expect(await Self.refusal(creating: S.expense(1, 19_999, on: "2026-11-20", fromSavingsMinor: 5_000), in: stores) == .notOneOff(thresholdMinor: 20_000))
    try await Self.create(S.expense(1, 20_000, on: "2026-11-20", fromSavingsMinor: 5_000), in: stores)
    #expect(try await Self.balance(in: stores).balanceMinor == 25_000)
  }

  @Test func shouldRefuseADrawWhenTheBudgetHasNoOneOffThreshold() async throws {
    let stores = try MemoirStores.openInMemory()
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings(), S.home(limitMinor: nil, createdOn: "2026-11-01")])
    #expect(await Self.refusal(creating: S.expense(1, 90_000, on: "2026-11-20", fromSavingsMinor: 1), in: stores) == .notOneOff(thresholdMinor: nil))
  }

  @Test func shouldDrawNoMoreThanSavingsHaveAvailable() async throws {
    let stores = try await Self.stores()
    #expect(
      await Self.refusal(creating: S.expense(1, 200_000, on: "2026-11-20", fromSavingsMinor: 130_001), in: stores) == .savingsInsufficient(availableMinor: 130_000))
    try await Self.create(S.expense(1, 200_000, on: "2026-11-20", fromSavingsMinor: 130_000), in: stores)
    let borrowed = try await Self.balance(in: stores)
    #expect(borrowed.balanceMinor == -100_000 && borrowed.availableMinor == 0 && borrowed.standing == .repaying(owedMinor: 100_000))
    #expect(await Self.refusal(creating: S.expense(2, 50_000, on: "2026-11-20", fromSavingsMinor: 1), in: stores) == .savingsInsufficient(availableMinor: 0))
  }

  @Test func shouldShowDrawsFromTwoDevicesBelowTheFloorAndBlockAnyFurtherOne() async throws {
    let stores = try await Self.stores([
      S.expense(1, 90_000, on: "2026-11-19", fromSavingsMinor: 80_000), S.expense(2, 90_000, on: "2026-11-20", fromSavingsMinor: 80_000),
    ])
    let merged = try await Self.balance(in: stores)
    #expect(merged.balanceMinor == -130_000, "each draw fit on its own device; together they go past the floor and are shown as they are")
    #expect(merged.availableMinor == 0)
    #expect(await Self.refusal(creating: S.expense(3, 50_000, on: "2026-11-21", fromSavingsMinor: 1), in: stores) == .savingsInsufficient(availableMinor: 0))
    _ = try await stores.main.write { transaction in
      try ExpenseEdits.update(MoneyReadsFixture.id(1), issuer: Self.issuer, in: &transaction) { $0.fromSavingsMinor = 70_000 }
    }
    #expect(try await Self.balance(in: stores).balanceMinor == -120_000, "lowering a draw is always allowed")
  }

  @Test func shouldWaitForARateBeforeDrawingForAForeignExpense() async throws {
    let stores = try await Self.stores([S.goal(1, target: 50_000, rank: "V")])
    #expect(await Self.refusal(creating: S.expense(1, 50_000, S.usd, on: "2026-11-20", fromSavingsMinor: 25_000), in: stores) == .savingsAwaitingRate)
    #expect(
      await Self.refusal(creating: S.expense(1, 5_000, S.usd, on: "2026-11-20", fromSavingsMinor: 5_000, goal: S.goalID(1)), in: stores) == .savingsAwaitingRate,
      "a goal purchase skips the one-off rule but still needs its amount in home")
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-20", "0.9")])
    try await Self.create(S.expense(1, 50_000, S.usd, on: "2026-11-20", fromSavingsMinor: 25_000), in: stores)
    #expect(try await Self.balance(in: stores).withdrawnMinor == 22_500)
  }

  @Test func shouldLetAGoalPurchaseDrawWithoutBeingAOneOff() async throws {
    let stores = try await Self.stores([S.goal(1, target: 50_000, rank: "V")])
    try await Self.create(S.expense(1, 1_000, on: "2026-11-20", fromSavingsMinor: 1_000, goal: S.goalID(1)), in: stores)
    #expect(try await Self.balance(in: stores).withdrawnMinor == 1_000)
  }

  @Test func shouldRefuseAGoalThatIsAbsentOrNotActive() async throws {
    let stores = try await Self.stores([S.goal(1, target: 50_000, rank: "V", state: .abandoned)])
    #expect(await Self.refusal(creating: S.expense(1, 1_000, on: "2026-11-20", goal: S.goalID(9)), in: stores) == .goalAbsent(S.goalID(9)))
    #expect(await Self.refusal(creating: S.expense(1, 1_000, on: "2026-11-20", fromSavingsMinor: 1_000, goal: S.goalID(1)), in: stores) == .goalNotActive(S.goalID(1)))
  }

  @Test func shouldBuyAGoalOnlyOnceItsCoolingOffHasPassedByTheExpensesDateAndToday() async throws {
    let stores = try await Self.stores([
      S.goal(1, target: 50_000, rank: "1", createdOn: "2026-11-18"), S.goal(2, target: 50_000, rank: "V", createdOn: "2026-11-19"),
      S.goal(3, target: 50_000, rank: "k", createdOn: "2026-11-15"),
    ])
    try await Self.create(S.expense(1, 1_000, on: "2026-11-21", fromSavingsMinor: 1_000, goal: S.goalID(1)), in: stores)
    #expect(
      await Self.refusal(creating: S.expense(2, 1_000, on: "2026-11-21", fromSavingsMinor: 1_000, goal: S.goalID(2)), in: stores)
        == .coolingOffNotMet(buyFrom: S.date("2026-11-22")), "two days are not three")
    #expect(
      await Self.refusal(creating: S.expense(2, 1_000, on: "2026-11-25", goal: S.goalID(2)), in: stores) == .coolingOffNotMet(buyFrom: S.date("2026-11-22")),
      "dating the purchase ahead does not shorten the cooling-off, even without a draw")
    #expect(
      await Self.refusal(creating: S.expense(2, 1_000, on: "2026-11-17", fromSavingsMinor: 1_000, goal: S.goalID(3)), in: stores)
        == .coolingOffNotMet(buyFrom: S.date("2026-11-18")), "a purchase dated inside the cooling-off is refused")
  }

  @Test func shouldCheckAnEditOnlyWhenItDrawsMoreOrNamesAnotherGoal() async throws {
    let stores = try await Self.stores([S.goal(1, target: 50_000, rank: "V")])
    try await Self.create(S.expense(1, 25_000, on: "2026-11-20", fromSavingsMinor: 10_000), in: stores)
    _ = try await stores.main.write { transaction in
      try ExpenseEdits.update(MoneyReadsFixture.id(1), issuer: Self.issuer, in: &transaction) { expense in
        expense.amountMinor = 15_000
        expense.fromSavingsMinor = 8_000
      }
    }
    #expect(try await Self.balance(in: stores).withdrawnMinor == 8_000, "an amount below the one-off threshold keeps a draw that falls")
    #expect(await Self.refusal(updating: 1, in: stores) { $0.fromSavingsMinor = 9_000 } == .notOneOff(thresholdMinor: 20_000), "a draw that rises is checked again")
    #expect(await Self.refusal(updating: 1, in: stores) { $0.amountMinor = 7_000 } == .savingsExceedsAmount(savings: 8_000, amount: 7_000))

    try await Self.create(S.expense(2, 1_000, on: "2026-11-20", fromSavingsMinor: 1_000, goal: S.goalID(1)), in: stores)
    _ = try await stores.main.write { transaction in try GoalEdits.markBought(S.goalID(1), issuer: Self.issuer, in: &transaction) }
    _ = try await stores.main.write { transaction in
      try ExpenseEdits.update(MoneyReadsFixture.id(2), issuer: Self.issuer, in: &transaction) { $0.note = "the bell" }
    }
    #expect(await Self.refusal(updating: 2, in: stores) { $0.goal = nil } == .notOneOff(thresholdMinor: 20_000), "a draw that no longer buys a goal must be a one-off")
  }

  @Test func shouldAcceptANoteEditOfAnExpenseWhoseMergedDrawExceedsItsAmount() async throws {
    let stores = try await Self.stores([S.expense(1, 10_000, on: "2026-11-20", fromSavingsMinor: 15_000)])
    let command = try await stores.main.write { transaction in
      try ExpenseEdits.update(MoneyReadsFixture.id(1), issuer: Self.issuer, in: &transaction) { $0.note = "returned the box" }
    }
    #expect(command != nil, "a draw read clamped to the amount has neither risen nor moved")
  }

  @Test func shouldStillRefundAnExpenseThatDrewOnSavings() async throws {
    let stores = try await Self.stores()
    try await Self.create(S.expense(1, 25_000, on: "2026-11-20", fromSavingsMinor: 25_000), in: stores)
    _ = try await stores.main.write { transaction in try ExpenseEdits.refund(MoneyReadsFixture.id(1), amount: .partial(10_000), issuer: Self.issuer, in: &transaction) }
    #expect(try await Self.balance(in: stores).withdrawnMinor == 15_000, "the refund returns what no longer fits to savings")
  }
}
