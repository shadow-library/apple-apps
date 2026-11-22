import Foundation
import MemoirCore
import ShadowStore
import Testing

@testable import Memoir

/// Reflect screens on in-memory stores at noon of `TestClock.day0` (a Monday) in UTC, with records written the way the log screens write them.
@MainActor
enum ReflectTesting {
  static func world(day: Int = 0) throws -> (context: MemoirScreenContext, clock: TestClock) {
    let clock = TestClock(day: day, minute: 720)
    return (try QuestsTesting.context(clock), clock)
  }

  static func seed(_ records: [any MemoirRecord], in store: VaultStore) async throws {
    try await store.write { transaction in
      for record in records { try record.create(in: &transaction) }
    }
  }

  static func meal(_ name: String, day: Int, minute: Int = 600) -> MealRecord {
    MealRecord(
      id: UUID(), date: TestClock.day(day), name: name, calories: 500, mealType: .known(.cooked), loggedAtMillis: TestClock.millis(day: day, minute: minute))
  }

  static func weight(_ kilograms: String, day: Int) -> WeightRecord {
    WeightRecord(date: TestClock.day(day), kilograms: DecimalText(kilograms)!, loggedAtMillis: TestClock.millis(day: day, minute: 420))
  }

  static func expense(_ minor: Int64, day: Int, merchant: String?, category: String = "food") -> ExpenseRecord {
    ExpenseRecord(
      id: UUID(), amountMinor: minor, currency: CurrencyCode("EUR")!, occurredOn: TestClock.day(day), category: CategoryKey(category)!, merchant: merchant,
      loggedAtMillis: TestClock.millis(day: day, minute: 540))
  }

  static func settings() -> AccountSettingsRecord {
    let euro = CurrencyCode("EUR")!
    return AccountSettingsRecord(defaultCurrency: euro, enabledCurrencies: [euro], monthlyBudget: nil)
  }

  static func logExpenses(_ expenses: [ExpenseRecord], in context: MemoirScreenContext) async throws {
    try await seed([settings()], in: context.stores.main)
    try await context.writer.write { issuer, transaction in
      for expense in expenses { try ExpenseEdits.create(expense, issuer: issuer, in: &transaction) }
    }
  }

  static func complete(_ quest: UUID, on day: Int, in context: MemoirScreenContext) async throws {
    try await context.writer.issue(.questComplete(Occurrence(quest: quest, date: TestClock.day(day))))
  }

  /// Runs `body` while the model follows the account's day, once the day is known, as the screen's own task does.
  static func following(_ day: ReflectDayFollower, _ body: () async throws -> Void) async throws {
    try await QuestsObservation { await day.follow() }.during {
      try await TestClock.until("the account's day is known") { day.day != nil }
      try await body()
    }
  }
}
