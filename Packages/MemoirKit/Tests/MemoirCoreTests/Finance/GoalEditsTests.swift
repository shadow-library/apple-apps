import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Goal edits", TestTimeLimit.standard)
struct GoalEditsTests {
  private typealias S = SavingsFixture

  private static func stores(_ records: [any MemoirRecord] = []) async throws -> MemoirStores {
    let stores = try MemoirStores.openInMemory()
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings(budgetMinor: 100_000), S.home()] + records)
    return stores
  }

  private static func draft(_ name: String = "Bike", target: Int64 = 50_000, date: String? = nil) -> GoalDraft {
    GoalDraft(name: name, symbol: "bicycle", targetMinor: target, targetDate: date.map(S.date))
  }

  @discardableResult
  private static func create(_ number: Int, _ draft: GoalDraft = draft(), in stores: MemoirStores) async throws -> SavingsGoalRecord {
    try await stores.main.write { transaction in try GoalEdits.create(draft, id: S.goalID(number), today: S.today, in: &transaction) }
  }

  private static func refusal(in stores: MemoirStores, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async -> FinanceError? {
    do {
      try await stores.main.write { transaction in try body(&transaction) }
      return nil
    } catch {
      switch error {
      case .aborted(let inner as FinanceError): return inner
      case .aborted(CommandIssueError.refused(.finance(let inner))): return inner
      default: return nil
      }
    }
  }

  private static func goals(in stores: MemoirStores) async throws -> [SavingsGoalRecord] {
    try await stores.main.read { transaction in try SavingsGoalRecord.listing(in: transaction) }.entries.filter { !$0.isRemoved }.map(\.record)
  }

  private static func goal(_ number: Int, in stores: MemoirStores) async throws -> SavingsGoalRecord {
    try #require(try await goals(in: stores).first { $0.id == S.goalID(number) })
  }

  @Test func shouldCreateAGoalInTheHomeCurrencyAfterTheLastActiveOne() async throws {
    let stores = try await Self.stores()
    let first = try await Self.create(1, Self.draft("  Bike  ", date: "2027-03-01"), in: stores)
    let second = try await Self.create(2, Self.draft("Laptop"), in: stores)
    #expect(first.name == "Bike" && first.symbol == "bicycle" && first.currency == S.eur && first.createdOn == S.today)
    #expect(first.state == .known(.active) && first.targetDate == S.date("2027-03-01"))
    #expect(first.rank < second.rank)
    #expect(try await Self.goals(in: stores).count == 2)
  }

  @Test func shouldRefuseAGoalWithoutItsDetails() async throws {
    let stores = try await Self.stores()
    let cases: [(GoalDraft, FinanceError)] = [
      (Self.draft("   "), .goalNameRequired), (GoalDraft(name: "Bike", symbol: " ", targetMinor: 1), .goalSymbolRequired),
      (Self.draft(target: 0), .goalTargetNotPositive(0)), (Self.draft(target: -5), .goalTargetNotPositive(-5)),
      (Self.draft(date: "2026-11-20"), .goalTargetDatePassed(earliest: S.today)),
    ]
    for (draft, expected) in cases {
      let refused = await Self.refusal(in: stores) { transaction in try GoalEdits.create(draft, id: S.goalID(1), today: S.today, in: &transaction) }
      #expect(refused == expected)
    }
    try await Self.create(1, Self.draft(date: "2026-11-21"), in: stores)
    #expect(await Self.refusal(in: stores) { transaction in try GoalEdits.create(Self.draft(), id: S.goalID(1), today: S.today, in: &transaction) } == .goalExists(S.goalID(1)))
    #expect(try await Self.goals(in: stores).count == 1, "a target date of today is allowed and refusals write nothing")

    let bare = try MemoirStores.openInMemory()
    #expect(await Self.refusal(in: bare) { transaction in try GoalEdits.create(Self.draft(), id: S.goalID(1), today: S.today, in: &transaction) } == .settingsAbsent)
  }

  @Test func shouldKeepAtMostThreeGoalsActive() async throws {
    let stores = try await Self.stores()
    for number in 1...3 { try await Self.create(number, in: stores) }
    let fourth = await Self.refusal(in: stores) { transaction in try GoalEdits.create(Self.draft(), id: S.goalID(4), today: S.today, in: &transaction) }
    #expect(fourth == .goalLimitReached(maximum: SavingsRules.maximumActiveGoals))
    try await stores.main.write { transaction in _ = try GoalEdits.abandon(S.goalID(2), in: &transaction) }
    try await Self.create(4, in: stores)
    #expect(try await Self.goal(4, in: stores).rank > Self.goal(3, in: stores).rank)
  }

  @Test func shouldEditTargetsOnlyOfActiveGoalsAndCheckADateOnlyWhenItMoves() async throws {
    let stores = try await Self.stores([S.goal(1, target: 20_000, rank: "V", targetDate: "2026-11-01")])
    let renamed = try await stores.main.write { transaction in try GoalEdits.update(S.goalID(1), today: S.today, in: &transaction) { $0.name = "Road bike" } }
    #expect(renamed?.name == "Road bike", "a goal whose date has passed can still be renamed")
    let unchanged = try await stores.main.write { transaction in try GoalEdits.update(S.goalID(1), today: S.today, in: &transaction) { _ in } }
    #expect(unchanged == nil)
    #expect(
      await Self.refusal(in: stores) { transaction in try GoalEdits.update(S.goalID(1), today: S.today, in: &transaction) { $0.targetDate = S.date("2026-11-20") } }
        == .goalTargetDatePassed(earliest: S.today))
    #expect(
      await Self.refusal(in: stores) { transaction in try GoalEdits.update(S.goalID(1), today: S.today, in: &transaction) { $0.targetMinor = 0 } } == .goalTargetNotPositive(0))
    let lowered = try await stores.main.write { transaction in try GoalEdits.update(S.goalID(1), today: S.today, in: &transaction) { $0.targetMinor = 15_000 } }
    #expect(lowered?.targetMinor == 15_000)

    try await stores.main.write { transaction in _ = try GoalEdits.abandon(S.goalID(1), in: &transaction) }
    #expect(
      await Self.refusal(in: stores) { transaction in try GoalEdits.update(S.goalID(1), today: S.today, in: &transaction) { $0.targetMinor = 9_000 } }
        == .goalNotActive(S.goalID(1)))
    let symbol = try await stores.main.write { transaction in try GoalEdits.update(S.goalID(1), today: S.today, in: &transaction) { $0.symbol = "bolt" } }
    #expect(symbol?.symbol == "bolt")
    #expect(await Self.refusal(in: stores) { transaction in try GoalEdits.update(S.goalID(9), today: S.today, in: &transaction) { $0.name = "X" } } == .goalAbsent(S.goalID(9)))
  }

  @Test func shouldReorderByRewritingOnlyTheMovedGoalsRank() async throws {
    let stores = try await Self.stores([S.goal(1, target: 1, rank: "F"), S.goal(2, target: 1, rank: "V"), S.goal(3, target: 1, rank: "k")])
    let moved = try await stores.main.write { transaction in try GoalEdits.reorder(S.goalID(3), toIndex: 0, in: &transaction) }
    #expect(try #require(moved).rank < (try #require(SavingsGoalRank("F"))))
    let goals = try await Self.goals(in: stores)
    #expect(goals.sorted(by: SavingsGoalRecord.precedes).map(\.id) == [S.goalID(3), S.goalID(1), S.goalID(2)])
    #expect(goals.first { $0.id == S.goalID(1) }?.rank.text == "F" && goals.first { $0.id == S.goalID(2) }?.rank.text == "V")

    let same = try await stores.main.write { transaction in try GoalEdits.reorder(S.goalID(1), toIndex: 1, in: &transaction) }
    #expect(same == nil, "a goal already at its place is not written")
    let middle = try await stores.main.write { transaction in try GoalEdits.reorder(S.goalID(3), toIndex: 9, in: &transaction) }
    #expect(try #require(middle).rank > (try #require(SavingsGoalRank("V"))), "an index past the end moves the goal last")
  }

  @Test func shouldSpreadEveryRankWhenNoneFitsBetweenTwoGoalsOfTheSameRank() async throws {
    let stores = try await Self.stores([S.goal(1, target: 1, rank: "V"), S.goal(2, target: 1, rank: "V"), S.goal(3, target: 1, rank: "k")])
    _ = try await stores.main.write { transaction in try GoalEdits.reorder(S.goalID(3), toIndex: 1, in: &transaction) }
    let order = try await Self.goals(in: stores).sorted(by: SavingsGoalRecord.precedes)
    #expect(order.map(\.id) == [S.goalID(1), S.goalID(3), S.goalID(2)])
    #expect(order.map(\.rank.text) == ["F", "V", "k"])
  }

  @Test func shouldPlaceAGoalAfterItsNeighbourWhateverLiesBetween() async throws {
    let stores = try await Self.stores([
      S.goal(1, target: 1, rank: "F"), S.goal(2, target: 1, rank: "V", currency: S.usd), S.goal(3, target: 1, rank: "k"), S.goal(4, target: 1, rank: "q", state: .bought),
    ])
    _ = try await stores.main.write { transaction in try GoalEdits.reorder(S.goalID(1), after: S.goalID(3), in: &transaction) }
    var order = try await Self.goals(in: stores).filter { $0.state == .known(.active) }.sorted(by: SavingsGoalRecord.precedes).map(\.id)
    #expect(order == [S.goalID(2), S.goalID(3), S.goalID(1)], "the goal in another currency keeps its place before the neighbour")
    _ = try await stores.main.write { transaction in try GoalEdits.reorder(S.goalID(1), after: nil, in: &transaction) }
    order = try await Self.goals(in: stores).filter { $0.state == .known(.active) }.sorted(by: SavingsGoalRecord.precedes).map(\.id)
    #expect(order == [S.goalID(1), S.goalID(2), S.goalID(3)])
    #expect(
      await Self.refusal(in: stores) { transaction in try GoalEdits.reorder(S.goalID(1), after: S.goalID(4), in: &transaction) } == .goalNotActive(S.goalID(4)))
    #expect(
      await Self.refusal(in: stores) { transaction in try GoalEdits.reorder(S.goalID(1), after: S.goalID(1), in: &transaction) } == .goalNotActive(S.goalID(1)),
      "a goal is never its own neighbour")
  }

  @Test func shouldRefuseToReorderAGoalThatIsNotActive() async throws {
    let stores = try await Self.stores([S.goal(1, target: 1, rank: "V", state: .bought)])
    #expect(await Self.refusal(in: stores) { transaction in try GoalEdits.reorder(S.goalID(1), toIndex: 0, in: &transaction) } == .goalNotActive(S.goalID(1)))
  }

  @Test func shouldBuyAGoalWithTheCommandWithinOrOverItsTarget() async throws {
    let purchase = S.expense(1, 45_000, on: "2026-11-20", fromSavingsMinor: 20_000, goal: S.goalID(1))
    let stores = try await Self.stores([S.goal(1, target: 50_000, rank: "V"), S.goal(2, target: 25_000, rank: "k"), purchase])
    let issuer = MoneyReadsFixture.issuer(on: S.today)
    let command = try #require(try await stores.main.write { transaction in try GoalEdits.markBought(S.goalID(1), issuer: issuer, in: &transaction) })
    #expect(try MemoirCommandBody(command) == .goalBought(GoalPurchase(goalId: S.goalID(1), outcome: .within)))
    #expect(try await Self.goal(1, in: stores).state == .known(.bought))
    #expect(
      await Self.refusal(in: stores) { transaction in try GoalEdits.markBought(S.goalID(1), issuer: issuer, in: &transaction) } == .goalNotActive(S.goalID(1)),
      "a goal is bought once")

    #expect(
      await Self.refusal(in: stores) { transaction in try GoalEdits.markBought(S.goalID(2), issuer: issuer, in: &transaction) } == .goalNotPurchased(S.goalID(2)))
    try await MoneyReadsFixture.seed(stores.main, [S.expense(2, 20_000, on: "2026-11-20", goal: S.goalID(2)), S.expense(3, 5_001, on: "2026-11-21", goal: S.goalID(2))])
    let over = try #require(try await stores.main.write { transaction in try GoalEdits.markBought(S.goalID(2), issuer: issuer, in: &transaction) })
    #expect(try MemoirCommandBody(over) == .goalBought(GoalPurchase(goalId: S.goalID(2), outcome: .over)))
  }

  @Test func shouldMarkAGoalTooSmallForRewardsBoughtWithoutTheCommand() async throws {
    let stores = try await Self.stores([S.goal(1, target: 24_999, rank: "V"), S.expense(1, 20_000, on: "2026-11-20", goal: S.goalID(1))])
    let command = try await stores.main.write { transaction in
      try GoalEdits.markBought(S.goalID(1), issuer: MoneyReadsFixture.issuer(on: S.today), in: &transaction)
    }
    #expect(command == nil, "below a quarter of Home's limit a goal earns nothing")
    #expect(try await Self.goal(1, in: stores).state == .known(.bought))
    #expect(try await stores.main.read { transaction in try ReadSources.commands(in: transaction).commands.count } == 0)
  }

  @Test func shouldWaitForARateBeforeBuyingAGoalWithAForeignPurchase() async throws {
    let stores = try await Self.stores([S.goal(1, target: 50_000, rank: "V"), S.expense(1, 45_000, S.usd, on: "2026-11-20", goal: S.goalID(1))])
    let refused = await Self.refusal(in: stores) { transaction in
      try GoalEdits.markBought(S.goalID(1), issuer: MoneyReadsFixture.issuer(on: S.today), in: &transaction)
    }
    #expect(refused == .savingsAwaitingRate)
    #expect(try await Self.goal(1, in: stores).state == .known(.active), "a refusal writes nothing")
  }

  @Test func shouldReturnAnAbandonedOrDeletedGoalsShareToSavings() async throws {
    let stores = try await Self.stores([
      S.deposit("2026-10", 30_000), S.goal(1, target: 20_000, rank: "F"), S.goal(2, target: 20_000, rank: "V"), S.goal(3, target: 20_000, rank: "k"),
    ])
    func shares() async throws -> [Int64] {
      try #require(try await SavingsReads.overview(in: stores, today: S.today)).allocation.active.map(\.shareMinor)
    }
    #expect(try await shares() == [20_000, 10_000, 0])
    let abandoned = try await stores.main.write { transaction in try GoalEdits.abandon(S.goalID(1), in: &transaction) }
    #expect(abandoned.state == .known(.abandoned))
    #expect(try await shares() == [20_000, 10_000])
    #expect(await Self.refusal(in: stores) { transaction in _ = try GoalEdits.abandon(S.goalID(1), in: &transaction) } == .goalNotActive(S.goalID(1)))
    try await stores.main.write { transaction in try GoalEdits.delete(S.goalID(2), in: &transaction) }
    #expect(try await shares() == [20_000])
    try await stores.main.write { transaction in try GoalEdits.delete(S.goalID(1), in: &transaction) }
    #expect(await Self.refusal(in: stores) { transaction in try GoalEdits.delete(S.goalID(1), in: &transaction) } == .goalAbsent(S.goalID(1)))
  }
}
