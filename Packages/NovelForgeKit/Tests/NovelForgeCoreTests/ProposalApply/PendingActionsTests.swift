import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private typealias World = ApplyWorld

private enum PendingActionsTestError: Error {
  case notResumed
}

extension ChapterBook {
  func pendingActionRows() async throws -> [PendingActionRow] {
    try await store.read { transaction in try PendingActions.rows(in: transaction.database) }
  }

  /// The content of a card approving and finalizing chapter 3, committed without running either action.
  func contentOnly() async throws -> UUID {
    try await reviewRead(3)
    let id = try await stage(World.approve3, World.finalize3).proposal.id
    let context = context()
    _ = try await run { try ProposalApply.apply(proposal: id, selection: .indexes([0, 1]), context: context, in: &$0) }
    return id
  }
}

// RULE E07: an apply records its pending actions beside the vault in its content transaction, and each action's transaction takes its index out
@Suite("Pending card actions", TestTimeLimit.standard)
struct PendingActionsTests {
  @Test func shouldRecordTheSelectedActionsInTheContentTransaction() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    #expect(try await book.pendingActionRows() == [PendingActionRow(proposal: id, novel: book.novel, actions: [0, 1], attempts: 0, fault: nil)])
    #expect(try await book.change(id, 0).actionOutcome == .known(.pending))
  }

  @Test func shouldRecordNothingForAnApplyWithoutActionsOrOneThatConflicts() async throws {
    let book = try await StagingWorld.workspace()
    let content = try await book.stage(World.premise).proposal.id
    #expect(try await book.applied(content).map(\.status) == [.applied])
    let refused = try await book.stage(World.approve3).proposal.id
    #expect(await book.applyError(refused) == .oneWayDoor(.actionApproveDraft))
    #expect(try await book.pendingActionRows().isEmpty)
  }

  @Test func shouldTakeEachSettledActionOutAndRemoveTheRowWithTheLast() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    let novel = book.novel
    #expect(
      try await book.run { try ProposalApply.runAction(proposal: id, index: 0, novel: novel, requester: SchemaFixture.requester, in: &$0) }
        == .ran(summary: "approved chapter 3's draft"))
    #expect(try await book.pendingActionRows().map(\.actions) == [[1]])
    #expect(try await book.run { try ProposalApply.runAction(proposal: id, index: 0, novel: novel, requester: SchemaFixture.requester, in: &$0) } == .settled(.known(.applied)))
    #expect(try await book.pendingActionRows().map(\.actions) == [[1]])
    #expect(
      try await book.run { try ProposalApply.runAction(proposal: id, index: 1, novel: novel, requester: SchemaFixture.requester, in: &$0) } == .ran(summary: "finalized chapter 3"))
    #expect(try await book.pendingActionRows().isEmpty)
  }

  @Test func shouldKeepTheRowWhenAnActionsTransactionIsAbandonedAndTakeOutWhatSettlesAsFailed() async throws {
    let book = try await StagingWorld.workspace()
    let head = try #require(try await book.head(3))
    let id = try await book.contentOnly()
    _ = try await book.save(3, "Mine.\n\n\(StagingText.body)", summary: "It turns.", base: head)
    let novel = book.novel
    await #expect(throws: (any Error).self) {
      try await book.run { try ProposalApply.runAction(proposal: id, index: 0, novel: novel, requester: SchemaFixture.requester, in: &$0) }
    }
    #expect(try await book.pendingActionRows().map(\.actions) == [[0, 1]])
    let failure = ProposalChangeFailure(.domain(.draftConflict(chapter: 3, head: head)))
    #expect(try await book.run { try ProposalApply.failAction(proposal: id, index: 0, novel: novel, failure: failure, in: &$0) } == .known(.failed))
    #expect(try await book.pendingActionRows().map(\.actions) == [[1]])
    let skipped = ProposalChangeFailure.previousActionFailed
    #expect(try await book.run { try ProposalApply.failAction(proposal: id, index: 1, novel: novel, failure: skipped, in: &$0) } == .known(.failed))
    #expect(try await book.pendingActionRows().isEmpty)
  }

  @Test func shouldLeaveNoRowAfterAnUninterruptedApply() async throws {
    let book = try await StagingWorld.workspace()
    try await book.reviewRead(3)
    let id = try await book.stage(World.approve3, World.finalize3).proposal.id
    #expect(try await book.applied(id, .indexes([0, 1])).map(\.status) == [.applied, .applied])
    #expect(try await book.pendingActionRows().isEmpty)
  }

  @Test func shouldStepOverUnreadableRowsAndKeepAnUnreadableListAsItIs() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    let novel = book.novel
    try await book.tamper("INSERT INTO nf_local_pending_action (proposal, novel, actions, recorded_at, attempts) VALUES (X'00', X'00', '0', 0, 0)")
    try await book.tamper("UPDATE nf_local_pending_action SET actions = '1,x' WHERE length(proposal) = 16")
    #expect(try await book.pendingActionRows() == [PendingActionRow(proposal: id, novel: novel, actions: nil, attempts: 0, fault: nil)])
    _ = try await book.run { try ProposalApply.runAction(proposal: id, index: 0, novel: novel, requester: SchemaFixture.requester, in: &$0) }
    #expect(try await book.pendingActionRows().map(\.actions) == [nil])
    try await book.run { try PendingActions.attempt(proposal: id, in: $0.database) }
    try await book.run { try PendingActions.fault(proposal: id, code: "store.failed", in: $0.database) }
    #expect(try await book.pendingActionRows() == [PendingActionRow(proposal: id, novel: novel, actions: nil, attempts: 1, fault: "store.failed")])
  }

  @Test func shouldReadNothingBeforeAnyApplyRecordedActions() async throws {
    let book = try await StagingWorld.workspace()
    #expect(try await book.pendingActionRows().isEmpty)
    #expect(await book.store.resumePendingActions().isEmpty)
    try await book.run { try PendingActions.settle(proposal: UUID(), index: 0, in: $0.database) }
  }

  @Test func shouldTakeOutAnIndexListedAfterItsActionSettled() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    let novel = book.novel
    for index in [0, 1] { _ = try await book.run { try ProposalApply.runAction(proposal: id, index: index, novel: novel, requester: SchemaFixture.requester, in: &$0) } }
    try await book.run { try PendingActions.record(proposal: id, novel: novel, actions: [0], at: Date(), in: $0.database) }
    #expect(try await book.run { try ProposalApply.runAction(proposal: id, index: 0, novel: novel, requester: SchemaFixture.requester, in: &$0) } == .settled(.known(.applied)))
    #expect(try await book.pendingActionRows().isEmpty)
  }

  @Test func shouldForgetTheRowOfACardNotFound() async throws {
    let book = try await StagingWorld.workspace()
    let (stray, novel) = (UUID(), book.novel)
    try await book.run { try PendingActions.record(proposal: stray, novel: novel, actions: [0], at: Date(), in: $0.database) }
    #expect(await book.store.resumePendingActions() == [.forgotten(proposal: stray, code: "RFN_001")])
    #expect(try await book.pendingActionRows().isEmpty)
  }

  @Test func shouldForgetAnUnreadableRowOnceItsCardHoldsNoPendingAction() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    let novel = book.novel
    for index in [0, 1] { _ = try await book.run { try ProposalApply.runAction(proposal: id, index: index, novel: novel, requester: SchemaFixture.requester, in: &$0) } }
    try await book.run { try PendingActions.record(proposal: id, novel: novel, actions: [1], at: Date(), in: $0.database) }
    try await book.tamper("UPDATE nf_local_pending_action SET actions = '1,x'")
    let settled = [ProposalActionResult(index: 0, outcome: .known(.applied)), ProposalActionResult(index: 1, outcome: .known(.applied))]
    #expect(await book.store.resumePendingActions() == [.resumed(proposal: id, settled)])
    #expect(try await book.pendingActionRows().isEmpty)
    #expect(try await book.approvals(3).count == 1)
  }

  @Test func shouldKeepAnUnreadableRowAsFaultedWhileAnActionIsPending() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.contentOnly()
    let novel = book.novel
    try await book.tamper("UPDATE nf_local_pending_action SET actions = '1,x'")
    try await book.tamper("DROP TABLE IF EXISTS nf_local_draft_working_copy; CREATE TABLE nf_local_draft_working_copy (novel BLOB, chapter INTEGER)")
    let resumes = await book.store.resumePendingActions()
    let row = try #require(try await book.pendingActionRows().first)
    #expect(resumes == [.faulted(proposal: id, code: try #require(row.fault))])
    #expect(row == PendingActionRow(proposal: id, novel: novel, actions: nil, attempts: 1, fault: row.fault))

    try await book.tamper("DROP TABLE nf_local_draft_working_copy")
    guard case .resumed(id, let results)? = await book.store.resumePendingActions().first else { throw PendingActionsTestError.notResumed }
    #expect(results.map(\.outcome) == [.known(.applied), .known(.applied)])
    #expect(try await book.pendingActionRows().isEmpty)
    #expect(try await book.final(3) != nil)
  }
}
