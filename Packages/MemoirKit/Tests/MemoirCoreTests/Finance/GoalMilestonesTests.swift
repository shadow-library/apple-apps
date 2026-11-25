import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Goal milestones", TestTimeLimit.standard)
struct GoalMilestonesTests {
  private typealias S = SavingsFixture

  private static let horizon = MoneyReadsFixture.stamp(S.today, hour: 23)

  private static func crossings(_ goal: Int, _ milestones: [GoalMilestone]) -> [GoalMilestoneCrossing] {
    milestones.map { GoalMilestoneCrossing(goal: S.goalID(goal), milestone: $0) }
  }

  /// Savings of 30 000 fill a 40 000 goal to 750 thousandths.
  private static func book(goals: [SavingsGoalRecord], expenses: [ExpenseRecord] = [], home: BudgetRecord = S.home()) -> SavingsBook {
    S.book(budgets: [home], expenses: expenses, deposits: S.steadyDeposits, goals: goals)
  }

  @Test func shouldListEveryMilestoneAGoalHasPassedInFillOrder() {
    let book = Self.book(goals: [S.goal(1, target: 40_000, rank: "b"), S.goal(2, target: 25_000, rank: "c"), S.goal(3, target: 100_000, rank: "a")])
    #expect(GoalMilestones.due(book, rewarded: [], today: S.today) == Self.crossings(3, [.p25]), "the first goal takes the whole 30 000")
    let filled = Self.book(goals: [S.goal(1, target: 40_000, rank: "a"), S.goal(2, target: 25_000, rank: "b")])
    #expect(GoalMilestones.due(filled, rewarded: [], today: S.today) == Self.crossings(1, [.p25, .p50, .p75]))
    let complete = Self.book(goals: [S.goal(1, target: 30_000, rank: "a")])
    #expect(GoalMilestones.due(complete, rewarded: [], today: S.today) == Self.crossings(1, [.p25, .p50, .p75, .p100]))
  }

  @Test func shouldLeaveOutRewardedMilestonesGoalsTooSmallForRewardsAndGoalsNoLongerActive() {
    let rewarded = Set(Self.crossings(1, [.p25, .p50]))
    #expect(GoalMilestones.due(Self.book(goals: [S.goal(1, target: 40_000, rank: "a")]), rewarded: rewarded, today: S.today) == Self.crossings(1, [.p75]))
    #expect(GoalMilestones.due(Self.book(goals: [S.goal(1, target: 24_999, rank: "a")]), rewarded: [], today: S.today).isEmpty, "under a quarter of Home's limit")
    #expect(GoalMilestones.due(Self.book(goals: [S.goal(1, target: 30_000, rank: "a")], home: S.home(limitMinor: nil)), rewarded: [], today: S.today).isEmpty)
    #expect(GoalMilestones.due(Self.book(goals: [S.goal(1, target: 30_000, rank: "a", state: .bought)]), rewarded: [], today: S.today).isEmpty)
    #expect(GoalMilestones.due(Self.book(goals: [S.goal(1, target: 30_000, rank: "a", state: .abandoned)]), rewarded: [], today: S.today).isEmpty)
  }

  @Test func shouldCountWhatAPurchaseDrewSoBuyingPartNeverUndoesAMilestone() {
    let goal = S.goal(1, target: 40_000, rank: "a", createdOn: "2026-10-01")
    let bought = S.expense(1, 20_000, on: "2026-11-10", fromSavingsMinor: 20_000, goal: goal.id)
    #expect(GoalMilestones.due(Self.book(goals: [goal], expenses: [bought]), rewarded: [], today: S.today) == Self.crossings(1, [.p25, .p50, .p75]))
  }

  @Test func shouldEarnNoMilestoneForAPurchaseBorrowedBelowZero() {
    let goal = S.goal(1, target: 40_000, rank: "a")
    let borrowed = S.book(budgets: [S.home()], expenses: [S.expense(1, 20_000, on: "2026-11-10", fromSavingsMinor: 20_000, goal: goal.id)], goals: [goal])
    #expect(GoalMilestones.due(borrowed, rewarded: [], today: S.today).isEmpty)
  }

  @Test func shouldEarnMilestonesOnlyUpToWhatThePoolHeldForAPartFundedPurchase() throws {
    let goal = S.goal(1, target: 40_000, rank: "a")
    let book = Self.book(goals: [goal], expenses: [S.expense(1, 40_000, on: "2026-11-10", fromSavingsMinor: 40_000, goal: goal.id)])
    let share = try #require(try S.overview(book).allocation.share(of: goal.id))
    #expect(share.progressThousandths == 1000 && share.savedThousandths == 750 && share.heldMinor == 30_000)
    #expect(GoalMilestones.due(book, rewarded: [], today: S.today) == Self.crossings(1, [.p25, .p50, .p75]), "10 000 of it was borrowed")
  }

  @Test func shouldListNothingWhileReplayIsHalted() {
    let book = Self.book(goals: [S.goal(1, target: 30_000, rank: "a")])
    let budgets = book.budgets
    let halted = SavingsBook(
      budgets: BudgetBook(
        settings: budgets.settings, assignments: budgets.assignments, rates: budgets.rates, coveredDays: budgets.coveredDays, closeInstants: [:],
        deposits: budgets.deposits, zone: budgets.zone, replayHalt: .rulesetUnavailable(command: MemoirStoreFixture.commandID(1), version: 9)),
      budgetRecords: book.budgetRecords, goals: book.goals, essentials: book.essentials)
    #expect(!GoalMilestones.due(book, rewarded: [], today: S.today).isEmpty)
    #expect(GoalMilestones.due(halted, rewarded: [], today: S.today).isEmpty)
  }

  @Test func shouldPayTheMilestonesOnceWhenAGoalIsMarkedBoughtBeforeTheCloserRuns() async throws {
    let stores = try MemoirStores.openInMemory(projection: try MemoirReconciler(appVersion: "1", horizon: { Self.horizon }))
    let goal = S.goal(1, target: 40_000, rank: "a")
    try await MoneyReadsFixture.seed(
      stores.main,
      [MoneyReadsFixture.settings(), S.home(), goal, S.expense(1, 20_000, on: "2026-11-10", fromSavingsMinor: 20_000, goal: goal.id)] + S.steadyDeposits)

    let bought = try await stores.main.write { transaction in try GoalEdits.markBought(goal.id, issuer: MoneyReadsFixture.issuer(on: S.today), in: &transaction) }
    #expect(bought?.payload.type.name == MemoirCommandKind.goalBought.rawValue)
    #expect(try await Self.rewards(in: stores.main) == [.milestone(.p25), .milestone(.p50), .milestone(.p75), .bought].map { GoalRewardRow(goal: goal.id, reward: $0) })
    let milestones = try await stores.main.read { transaction in try Replay.commands(in: transaction) }.count { command in
      guard case .readable(let entry) = command else { return false }
      return entry.record.payload.type.name == MemoirCommandKind.goalMilestone.rawValue
    }
    #expect(milestones == 3)

    let later = try await stores.main.write { transaction in try GoalMilestones.issue(issuer: MoneyReadsFixture.issuer(on: S.today, hour: 15), in: &transaction) }
    #expect(later.isEmpty, "the closer finds nothing more to pay")
  }

  @Test func shouldRefuseToMarkAGoalBoughtWhileReplayIsHaltedSoItsMilestonesAreNotLost() async throws {
    let stores = try MemoirStores.openInMemory(projection: try MemoirReconciler(appVersion: "1", horizon: { Self.horizon }))
    let goal = S.goal(1, target: 40_000, rank: "a")
    try await MoneyReadsFixture.seed(
      stores.main,
      [MoneyReadsFixture.settings(), S.home(), goal, S.expense(1, 20_000, on: "2026-11-10", fromSavingsMinor: 20_000, goal: goal.id)] + S.steadyDeposits)
    try await MoneyReadsFixture.write(stores.main) { transaction in
      let future = try MemoirCommand(
        id: MemoirStoreFixture.commandID(99), payload: try CommandPayload(type: try CommandType("future.feature")), instantMillis: MoneyReadsFixture.millis(S.today),
        utcOffsetMinutes: 0, issuedOn: S.today, rulesetVersion: Ruleset.v2.version)
      try future.append(in: &transaction)
    }

    do {
      _ = try await stores.main.write { transaction in try GoalEdits.markBought(goal.id, issuer: MoneyReadsFixture.issuer(on: S.today), in: &transaction) }
      Issue.record("marking bought goes on while replay is halted")
    } catch let error as StoreError {
      guard case .aborted(let inner as CommandIssueError) = error, case .refused(.finance(.replayHalted)) = inner else { throw error }
      #expect(inner.code == "memoir_finance.replay_halted")
    }
    let stored = try await stores.main.read { transaction in try SavingsGoalRecord.read(id: goal.id, in: transaction).entry?.record }
    #expect(stored?.state == .known(.active))
    #expect(try await stores.main.read { transaction in try transaction.states(ofKind: MemoirKind.command.entityKind, scope: .vault).count } == 1)
  }

  @Test func shouldIssueNothingAndGrowNoCommandsWhileReplayIsHalted() async throws {
    let stores = try MemoirStores.openInMemory(projection: try MemoirReconciler(appVersion: "1", horizon: { Self.horizon }))
    try await MoneyReadsFixture.seed(stores.main, Self.seed())
    try await MoneyReadsFixture.write(stores.main) { transaction in
      let future = try MemoirCommand(
        id: MemoirStoreFixture.commandID(99), payload: try CommandPayload(type: try CommandType("future.feature")), instantMillis: MoneyReadsFixture.millis(S.today),
        utcOffsetMinutes: 0, issuedOn: S.today, rulesetVersion: Ruleset.v2.version)
      try future.append(in: &transaction)
    }
    for hour in 12..<15 {
      #expect(try await Self.due(in: stores.main).isEmpty)
      let issued = try await stores.main.write { transaction in try GoalMilestones.issue(issuer: MoneyReadsFixture.issuer(on: S.today, hour: hour), in: &transaction) }
      #expect(issued.isEmpty)
    }
    #expect(try await stores.main.read { transaction in try transaction.states(ofKind: MemoirKind.command.entityKind, scope: .vault).count } == 1)
  }

  private static func seed() -> [any MemoirRecord] {
    [MoneyReadsFixture.settings(), S.home(), S.goal(1, target: 40_000, rank: "a"), S.goal(2, target: 10_000, rank: "b")] + S.steadyDeposits
  }

  private static func rewards(in store: VaultStore) async throws -> [GoalRewardRow] {
    try await store.read { transaction in try MemoirDerived.goalRewards(of: S.goalID(1), in: transaction) + MemoirDerived.goalRewards(of: S.goalID(2), in: transaction) }
  }

  private static func due(in store: VaultStore) async throws -> [GoalMilestoneCrossing] {
    try await store.read { transaction in try GoalMilestones.due(in: transaction, today: S.today) }
  }

  @Test func shouldIssueEveryDueMilestoneInOneWriteAndNothingOnceReplayRecordedThem() async throws {
    let stores = try MemoirStores.openInMemory(projection: try MemoirReconciler(appVersion: "1", horizon: { Self.horizon }))
    try await MoneyReadsFixture.seed(stores.main, Self.seed())
    #expect(try await GoalMilestones.due(in: stores, today: S.today) == Self.crossings(1, [.p25, .p50, .p75]))

    let issued = try await stores.main.write { transaction in try GoalMilestones.issue(issuer: MoneyReadsFixture.issuer(on: S.today), in: &transaction) }
    #expect(issued.map(\.payload.type.name) == Array(repeating: MemoirCommandKind.goalMilestone.rawValue, count: 3))
    #expect(try await Self.rewards(in: stores.main) == [.p25, .p50, .p75].map { GoalRewardRow(goal: S.goalID(1), reward: .milestone($0)) })
    #expect(try await Self.due(in: stores.main).isEmpty)
    let again = try await stores.main.write { transaction in try GoalMilestones.issue(issuer: MoneyReadsFixture.issuer(on: S.today), in: &transaction) }
    #expect(again.isEmpty)
  }

  @Test func shouldRewardEachMilestoneOnceWhenTwoDevicesIssueItAndRepeatNothingAfterReplaySupersedesTheLaterOnes() async throws {
    let reconcilers = try (0..<2).map { _ in try MemoirReconciler(appVersion: "1", horizon: { Self.horizon }) }
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry, reconciler: { reconcilers[$0] }))
    let seed = Self.seed()
    _ = try await replicas.write(0) { transaction in for record in seed { try record.create(in: &transaction) } }
    try await replicas.settle()

    var issued = [MemoirCommand]()
    for index in 0..<2 {
      await replicas.advanceClock(of: index, by: .seconds(index + 1))
      issued += try await replicas.write(index) { transaction in
        try GoalMilestones.issue(issuer: MoneyReadsFixture.issuer(on: S.today, hour: 12 + index), in: &transaction)
      }
    }
    #expect(issued.count == 6, "each device saw three milestones due while offline")
    try await replicas.settle()

    for index in 0..<2 {
      let store = await replicas.store(index)
      #expect(try await Self.rewards(in: store).count == 3, "one reward per milestone")
      let outcomes = Replay.run(try await ProjectionSupport.commands(in: store), through: Self.horizon).outcomes
      #expect(issued.count { outcomes[$0.id] == .applied } == 3 && issued.count { outcomes[$0.id] == .superseded } == 3)
      #expect(try await Self.due(in: store).isEmpty)
      let again = try await replicas.write(index) { transaction in
        try GoalMilestones.issue(issuer: MoneyReadsFixture.issuer(on: S.today, hour: 15), in: &transaction)
      }
      #expect(again.isEmpty)
    }
  }
}
