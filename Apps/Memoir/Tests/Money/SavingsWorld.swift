import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

/// A euro vault on `TestClock.day0` (2026-03-02) whose Home, created in September 2025 with a €1,000 limit and a €200 one-off threshold, closed four
/// months depositing €100 each: €400 saved, €1,000 more to borrow, a pace of €100 a month.
@MainActor
struct SavingsWorld {
  nonisolated static let bike = UUID(uuidString: "0190f3a0-0000-7000-8000-00000000b001")!
  nonisolated static let laptop = UUID(uuidString: "0190f3a0-0000-7000-8000-00000000b002")!
  nonisolated static let trip = UUID(uuidString: "0190f3a0-0000-7000-8000-00000000b003")!
  nonisolated static let sofa = UUID(uuidString: "0190f3a0-0000-7000-8000-00000000b004")!
  nonisolated static let homeLimit: Int64 = 100_000
  nonisolated static let oneOff: Int64 = 20_000
  nonisolated static let english = MoneyFixture.english

  let clock: TestClock
  let context: MemoirScreenContext

  init(deposits: [Int64] = [10_000, 10_000, 10_000, 10_000], goals: [SavingsGoalRecord] = [SavingsWorld.goal(SavingsWorld.bike)]) async throws {
    clock = TestClock(day: 0, minute: 720)
    context = try MemoirScreenContext.inMemory(clock: clock.memoir(deviceZone: TestClock.utc))
    let euro = MoneyFixture.euro
    let settings = AccountSettingsRecord(defaultCurrency: euro, enabledCurrencies: [euro, MoneyFixture.krone])
    let home = BudgetRecord(
      id: HomeBudget.id, currency: euro, limitMinor: Self.homeLimit, period: .monthly, oneOffFromMinor: Self.oneOff, createdOn: Self.date("2025-09-01"))
    let first = Self.date("2025-11-01")
    let records: [any MemoirRecord] =
      [settings, home]
      + deposits.enumerated().map { index, amount in Self.deposit(first.adding(months: index)!, amount) }
      + goals
    try await write(records)
  }

  nonisolated static func date(_ text: String) -> LocalDate {
    LocalDate(isoString: text)!
  }

  nonisolated static func goal(
    _ id: UUID, name: String = "New bike", target: Int64 = 100_000, rank: String = "1", createdOn: String = "2026-02-01", state: SavingsGoalState = .active,
    targetDate: String? = nil
  ) -> SavingsGoalRecord {
    SavingsGoalRecord(
      id: id, name: name, symbol: "bicycle", targetMinor: target, currency: MoneyFixture.euro, targetDate: targetDate.map(date), rank: SavingsGoalRank(rank)!,
      createdOn: date(createdOn), state: .known(state))
  }

  nonisolated static func deposit(_ month: LocalDate, _ amount: Int64) -> SavingsDepositRecord {
    SavingsDepositRecord(
      budget: HomeBudget.id, periodStart: month,
      deposit: SavingsDeposit(
        amountMinor: amount, currency: MoneyFixture.euro, closedOn: month.adding(months: 1)!.adding(days: 3)!, command: UUID(), spentMinor: homeLimit - amount,
        limitMinor: homeLimit, medianExpenseMinor: 1_000))
  }

  func write(_ records: [any MemoirRecord]) async throws {
    try await context.writer.write { _, transaction in
      for record in records { try record.create(in: &transaction) }
    }
  }

  /// An expense written as a record, past `ExpenseEdits`' checks, as one synced in from another device would arrive.
  @discardableResult
  func expense(_ amount: Int64, fromSavings: Int64? = nil, goal: UUID? = nil, note: String? = nil, on date: LocalDate = TestClock.day0) async throws
    -> ExpenseRecord
  {
    let expense = ExpenseRecord(
      id: UUID.v7(at: context.clock.now()), amountMinor: amount, currency: MoneyFixture.euro, occurredOn: date, category: MoneyFixture.food, note: note,
      fromSavingsMinor: fromSavings, goal: goal, loggedAtMillis: MemoirClock.millis(context.clock.now()))
    try await write([expense])
    return expense
  }

  func snapshot() async throws -> SavingsSnapshot {
    let clock = context.clock
    return try #require(try await context.stores.main.read { transaction in try SavingsSnapshot.load(in: transaction, clock: clock) })
  }

  func goals() async throws -> [MemoirEntry<SavingsGoalRecord>] {
    try await context.stores.main.read { transaction in try SavingsGoalRecord.listing(in: transaction).entries }
  }

  func goal(_ id: UUID) async throws -> SavingsGoalRecord {
    try #require(try await goals().first { $0.record.id == id && !$0.isRemoved }?.record)
  }

  func form(_ mode: ExpenseForm.Mode = .create, locale: Locale = SavingsWorld.english) async throws -> ExpenseForm {
    ExpenseForm(mode: mode, options: try await MoneyFixture.options(context), context: context, locale: locale)
  }
}
