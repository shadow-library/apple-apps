import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir money projection", TestTimeLimit.standard)
struct MoneyProjectionTests {
  private static let start = LocalDate(daysSinceEpoch: ReplaySamples.firstDay)!
  private static let key = MoneyCloseKey(budget: CommandSamples.budget, periodStart: LocalDate(daysSinceEpoch: ReplaySamples.firstDay - 31)!)

  private static func command(_ number: Int, _ body: MemoirCommandBody, plus offset: Int) throws -> MemoirCommand {
    try ProjectionSupport.command(MemoirStoreFixture.commandID(number), body, at: try ProjectionSupport.stamp(start, plus: offset), rulesetVersion: Ruleset.v2.version)
  }

  private static func close(_ number: Int, _ outcome: BudgetCloseOutcome, deposited: Bool, plus offset: Int) throws -> MemoirCommand {
    try command(number, .budgetClosePeriod(try BudgetPeriodClose(budgetId: key.budget, periodStart: key.periodStart, outcome: outcome, deposited: deposited)), plus: offset)
  }

  @Test func shouldProjectMoneyStateAndReadItThroughMemoirDerived() async throws {
    let clock = MemoirTestClock()
    let reconciler = try MemoirReconciler(appVersion: "1")
    let store = try MemoirStore.openInMemory(.main, wallClock: clock.function, projection: reconciler)
    var commands = try (0..<3).map { offset in
      try Self.command(1 + offset, .moneyNoSpend(NoSpendDay(date: try #require(Self.start.adding(days: offset)))), plus: offset)
    }
    commands.append(try Self.command(10, .goalMilestone(GoalMilestoneReached(goalId: CommandSamples.goal, milestone: .p50)), plus: 3))
    commands.append(try Self.command(11, .goalBought(GoalPurchase(goalId: CommandSamples.goal, outcome: .within)), plus: 3))
    for command in commands {
      clock.advance(seconds: 86_400)
      try await ProjectionSupport.append([command], to: store)
    }
    clock.advance(seconds: 86_400)
    let within = try Self.close(20, .within, deposited: true, plus: 4)
    try await ProjectionSupport.append([within], to: store)

    let read = try await store.read { transaction in
      (
        money: try MemoirDerived.money(in: transaction), covered: try MemoirDerived.coveredDays(from: Self.start, through: Self.start.movedBy(days: 1), in: transaction),
        close: try MemoirDerived.moneyClose(Self.key, in: transaction), rewards: try MemoirDerived.goalRewards(of: CommandSamples.goal, in: transaction)
      )
    }
    #expect(read.covered.map(\.date) == [Self.start, Self.start.movedBy(days: 1)] && read.covered.allSatisfy { $0.source == .noSpend })
    #expect(read.money?.savingStreak == 1 && read.money?.lastActivityDay == Self.start.movedBy(days: 4) && read.money?.debuff == nil)
    #expect(read.close?.close.command == within.id && read.close?.close.result == .rewarded(RewardAmount(xp: 20, coins: 3)))
    #expect(read.rewards.map(\.reward) == [.milestone(.p50), .bought])
    let events = try await store.read { transaction in
      (recent: try MemoirDerived.recentHeroEvents(in: transaction), all: try MemoirDerived.heroEvents(in: transaction))
    }
    #expect(events.all.filter { $0.event.type == .moneyLog }.count == 3)
    #expect(!events.recent.contains { $0.event.type == .moneyLog }, "the daily money log never crowds the recent events")
    #expect(events.recent.contains { $0.event.type == .goalBought })
    #expect(try await ProjectionSupport.derived(in: store) == (try await ProjectionSupport.expected(in: store, through: nil)))

    let offline = try MemoirStore.openInMemory(.main, wallClock: { Date(timeIntervalSince1970: 1_700_000_000 + 4 * 86_400 + 60) })
    let earlier = try Self.close(30, .overMore, deposited: false, plus: 4)
    try await ProjectionSupport.append([earlier], to: offline)
    _ = try await store.applyRemote(try await offline.pendingChanges(limit: Int.max).map(\.line))

    let after = try await store.read { transaction in
      (money: try MemoirDerived.money(in: transaction), closes: try MemoirDerived.moneyCloses(in: transaction))
    }
    #expect(after.closes.map(\.close.command) == [earlier.id], "the earlier-clocked close takes the period once it arrives")
    #expect(after.money?.savingStreak == 0)
    #expect(after.money?.debuff == MoneyRow.Debuff(multiplier: Thousandths(600), through: Self.start.movedBy(days: 33)))
    let commandsAfter = try await ProjectionSupport.commands(in: store)
    #expect(Replay.run(commandsAfter).outcomes[within.id] == .superseded)
    #expect(try await ProjectionSupport.derived(in: store) == (try await ProjectionSupport.expected(in: store, through: nil)))
  }

  @Test func shouldReadNothingBeforeTheProjectionHasRun() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let read = try await store.read { transaction in
      (
        money: try MemoirDerived.money(in: transaction), covered: try MemoirDerived.coveredDays(from: Self.start, through: Self.start, in: transaction),
        closes: try MemoirDerived.moneyCloses(in: transaction), close: try MemoirDerived.moneyClose(Self.key, in: transaction),
        rewards: try MemoirDerived.goalRewards(of: CommandSamples.goal, in: transaction)
      )
    }
    #expect(read.money == nil && read.covered.isEmpty && read.closes.isEmpty && read.close == nil && read.rewards.isEmpty)
  }

  @Test func shouldRoundTripEveryMoneyRowThroughItsTable() async throws {
    let reconciler = try MemoirReconciler(appVersion: "1")
    let store = try MemoirStore.openInMemory(.main, projection: reconciler)
    let commands = [
      try Self.command(1, .expenseCreate(ExpenseCreation(id: CommandSamples.record, occurredOn: Self.start)), plus: 0),
      try Self.close(2, .over25, deposited: false, plus: 0),
      try Self.command(
        3, .budgetClosePeriod(try BudgetPeriodClose(budgetId: CommandSamples.goal, periodStart: Self.key.periodStart, outcome: .withinTypical, deposited: true)), plus: 0),
      try Self.command(4, .goalMilestone(GoalMilestoneReached(goalId: CommandSamples.goal, milestone: .p100)), plus: 0),
    ]
    try await ProjectionSupport.append(commands, to: store)
    let stored = try await ProjectionSupport.derived(in: store)
    let expected = try await ProjectionSupport.expected(in: store, through: nil)
    #expect(stored == expected)
    #expect(stored.moneyCloses.count == 2 && stored.moneyDays.map(\.source) == [.expense] && stored.goalRewards.count == 1)
    #expect(stored.money.first?.debuff?.multiplier == Thousandths(750))
  }
}
