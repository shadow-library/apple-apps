import Foundation
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Pending card action standings", .timeLimit(.minutes(3)))
struct ChatPendingActionStandingTests {
  @Test func shouldReadTheNovelsRowsWithTheirAttemptsAndFault() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    let novel = book.novel
    let read = { () async throws -> [UUID: ChatPendingActionStanding] in
      try await book.store.read { transaction in try ChatPendingActionStanding.load(novel: novel, in: transaction) }
    }
    #expect(try await read() == [id: ChatPendingActionStanding(proposal: id, attempts: 0, fault: nil)])

    for _ in 0..<PendingActions.attemptLimit { try await book.run { try PendingActions.attempt(proposal: id, in: $0.database) } }
    try await book.run { try PendingActions.fault(proposal: id, code: "refinement.actions_unsettled", in: $0.database) }

    let standing = try #require(try await read()[id])
    #expect(standing.attempts == PendingActions.attemptLimit && standing.fault == "refinement.actions_unsettled" && standing.isGivenUp)
    #expect(try await book.store.read { transaction in try ChatPendingActionStanding.load(novel: UUID(), in: transaction) }.isEmpty)
  }

  @Test func shouldRunAGivenUpCardsActionsAgainAndForgetItsRow() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    let novel = book.novel
    for _ in 0..<PendingActions.attemptLimit { try await book.run { try PendingActions.attempt(proposal: id, in: $0.database) } }

    #expect(try await book.store.retryPendingActions(id, novel: novel).isEmpty)

    #expect(try await book.pendingActionRows().isEmpty)
    #expect(try await book.change(id, 0).actionOutcome == .known(.applied))
    #expect(try await book.change(id, 1).actionOutcome == .known(.applied))
  }

  @Test func shouldKeepAStalledRowWithEveryPendingIndexAndTheSweepsFault() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    let novel = book.novel
    for _ in 0..<PendingActions.attemptLimit { try await book.run { try PendingActions.attempt(proposal: id, in: $0.database) } }
    try await book.run { try PendingActions.fault(proposal: id, code: "earlier.fault", in: $0.database) }
    try await book.tamper("DROP TABLE IF EXISTS nf_local_draft_working_copy; CREATE TABLE nf_local_draft_working_copy (novel BLOB, chapter INTEGER)")

    #expect(try await book.store.retryPendingActions(id, novel: novel) == [0, 1])

    let row = try #require(try await book.pendingActionRows().first)
    #expect(row.attempts == PendingActions.attemptLimit && row.actions == [0, 1])
    #expect(row.fault != nil && row.fault != "earlier.fault")
    #expect(try await book.change(id, 0).actionOutcome == .known(.pending))
  }

  @Test func shouldForgetARowWhoseCardHoldsNoPendingActionEvenWhenItsListSaysOtherwise() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    let novel = book.novel
    for index in [0, 1] { _ = try await book.run { try ProposalApply.runAction(proposal: id, index: index, novel: novel, requester: SchemaFixture.requester, in: &$0) } }
    try await book.run { try PendingActions.record(proposal: id, novel: novel, actions: [1], at: Date(), in: $0.database) }
    try await book.tamper("UPDATE nf_local_pending_action SET actions = '1,x'")

    #expect(try await book.store.retryPendingActions(id, novel: novel).isEmpty)
    #expect(try await book.pendingActionRows().isEmpty)
  }

  @Test func shouldReadNothingBeforeAnyApplyRecordedActions() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    #expect(try await book.store.read { transaction in try ChatPendingActionStanding.load(novel: novel, in: transaction) }.isEmpty)
  }
}
