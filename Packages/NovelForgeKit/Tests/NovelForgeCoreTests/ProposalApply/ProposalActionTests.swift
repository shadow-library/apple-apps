import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private typealias World = ApplyWorld
private typealias Text = StagingText

private func only(_ outcomes: [ProposalChangeOutcome], _ index: Int) throws -> ProposalChangeOutcome {
  try #require(outcomes.first { $0.index == index })
}

/// Two volumes, `volume_1` active and `volume_2` next.
private func volumes(_ book: ChapterBook) async throws {
  try await book.volume("volume_1", ordinal: 1)
  try await book.volume("volume_2", ordinal: 2)
}

// apps/novel-forge-server/src/modules/refinement/proposal-apply.service.ts:220-290 and the executors of hub-action.registrar.ts, volume-action.registrar.ts
@Suite("Proposal actions", TestTimeLimit.standard)
struct ProposalActionTests {
  // proposal-draft-ops.spec.ts:254: the approval binds exactly the revision the card was staged against
  @Test func shouldApproveExactlyTheRevisionTheCardWasStagedAgainst() async throws {
    let book = try await StagingWorld.workspace()
    let head = try #require(try await book.head(3))
    let id = try await book.stage(World.approve3).proposal.id
    let outcome = try only(try await book.applied(id, .indexes([0])), 0)
    #expect(outcome.status == .applied)
    #expect(outcome.summary == "approved chapter 3's draft")
    #expect(try await book.approvals(3).map(\.draftRevision) == [head])
    let change = try await book.change(id, 0)
    #expect(change.actionOutcome == .known(.applied))
    #expect(change.result?.result == ["summary": "approved chapter 3's draft"])
  }

  // generation.service.ts:463 (DRF_013): unsaved edits over the staged head are not what the author would approve, so neither is approved and the copy stays
  @Test func shouldRefuseAnApprovalOverUnsavedEdits() async throws {
    let book = try await StagingWorld.workspace()
    let head = try #require(try await book.head(3))
    let id = try await book.stage(World.approve3, World.finalize3).proposal.id
    try await book.save(3, "Mine.\n\n\(Text.body)", summary: "It turns.", base: head)
    let outcomes = try await book.applied(id, .indexes([0, 1]))
    #expect(outcomes.map(\.failure) == [ProposalChangeFailure(.domain(.draftConflict(chapter: 3, head: head))), .previousActionFailed])
    #expect(try await book.approvals(3).isEmpty)
    #expect(try await book.final(3) == nil)
    #expect(try await book.workingCopy(3)?.content.body.hasPrefix("Mine.") == true)
  }

  // A copy holding the head's own text changes nothing the author sees
  @Test func shouldApproveUnderACopyThatHoldsTheHeadsOwnText() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    let head = try #require(try await book.head(3))
    let content = try #require(try await book.draftContent(3))
    let id = try await book.stage(World.approve3).proposal.id
    try await book.run { transaction in try DraftWorkingCopy(novel: novel, chapter: 3, base: head, content: content).save(in: transaction.database) }
    #expect(try only(try await book.applied(id, .indexes([0])), 0).status == .applied)
    #expect(try await book.approvals(3).map(\.draftRevision) == [head])
  }

  // A finalize over unsaved edits would freeze text the author no longer sees; the canon is abandoned with the action's transaction
  @Test func shouldRefuseToFinalizeOverUnsavedEdits() async throws {
    let book = try await StagingWorld.workspace()
    try await book.save(3, "Mine.\n\n\(Text.body)", summary: "It turns.", base: try await book.head(3))
    try await book.approve(3)
    try await book.reviewRead(3)
    let id = try await book.stage(World.finalize3).proposal.id
    #expect(try await book.workingCopy(3) != nil)
    #expect(try only(try await book.applied(id, .indexes([0])), 0).failure == ProposalChangeFailure(.domain(.draftNotApproved(3))))
    #expect(try await book.final(3) == nil)
    #expect(try await book.workingCopy(3)?.content.body.hasPrefix("Mine.") == true)
  }

  // proposal-draft-ops.spec.ts:270-281 (DRF_013): a head that moved since staging is never approved in its place
  @Test func shouldRefuseAnApprovalOfAHeadThatMovedSinceStaging() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(World.approve3).proposal.id
    try await book.reviseElsewhere(3, "Theirs.\n\n\(Text.body)")
    let head = try await book.head(3)
    let outcome = try only(try await book.applied(id, .indexes([0])), 0)
    #expect(outcome.status == .failed)
    #expect(outcome.failure == ProposalChangeFailure(.domain(.draftConflict(chapter: 3, head: head))))
    #expect(try await book.approvals(3).isEmpty)
    #expect(try await book.change(id, 0).actionOutcome == .known(.failed))
    #expect(try await book.decision(id) == .known(.applied))
  }

  // RULES F15: this device's copy over an earlier head is refused, as staging the approval is
  @Test func shouldRefuseAnApprovalWhileThisDevicesCopyRestsOnAnEarlierHead() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(World.approve3).proposal.id
    try await book.save(3, "Mine.\n\n\(Text.body)", summary: "It turns.", base: try await book.head(3))
    try await book.reviseElsewhere(3, "Theirs.\n\n\(Text.body)")
    let outcome = try only(try await book.applied(id, .indexes([0])), 0)
    #expect(outcome.failure == ProposalChangeFailure(.refused(.approvalOverMovedDraft(chapter: 3))))
    #expect(try await book.approvals(3).isEmpty)
    #expect(try await book.workingCopy(3)?.content.body.hasPrefix("Mine.") == true)
  }

  // proposal-draft-ops.spec.ts:262 and proposal-apply.service.ts:58: an approval beside the card's own edit approves the revision that edit wrote
  @Test func shouldApproveTheRevisionTheCardsOwnEditWrote() async throws {
    let book = try await StagingWorld.workspace()
    let staged = try await book.head(3)
    let id = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#, World.approve3).proposal.id
    let outcomes = try await book.applied(id, .indexes([0, 1]))
    #expect(outcomes.map(\.status) == [.applied, .applied])
    let head = try #require(try await book.head(3))
    #expect(head != staged)
    #expect(try await book.approvals(3).map(\.draftRevision) == [head])
  }

  // proposal-draft-ops.spec.ts:284: a card staged for a chapter without a draft reports the missing draft
  @Test func shouldReportAnApprovalForAChapterWithoutADraftAsAMissingDraft() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(#"{"op":"action.approve_draft","chapter":4}"#).proposal.id
    let outcome = try only(try await book.applied(id, .indexes([0])), 0)
    #expect(outcome.failure == ProposalChangeFailure(.domain(.draftNotFound(4))))
  }

  // hub-action.registrar.ts:72: a card that names no revision never approves whatever the draft now holds
  @Test func shouldRefuseAnApprovalStagedWithoutAStamp() async throws {
    let book = try await StagingWorld.workspace()
    let card = try await book.stage(World.approve3).proposal.card
    let head = try await book.head(3)
    for unstamped in [World.approve3, #"{"op":"action.approve_draft","chapter":3,"revision":1,"saveSeq":0,"draftId":"11"}"#] {
      var members = try #require(card.json.objectValue)
      members[ProposalCardMember.changeSet.rawValue] = .array([try #require(try OrderedJSON(parsing: unstamped).storable)])
      let rewritten = try #require(ProposalCard(json: .object(members)))
      let id = UUID()
      try await book.run { transaction in _ = try ProposalRecord(id: id, card: rewritten).create(in: &transaction) }
      let outcome = try only(try await book.applied(id, .indexes([0])), 0)
      #expect(outcome.failure == ProposalChangeFailure(.domain(.draftConflict(chapter: 3, head: head))))
    }
    #expect(try await book.approvals(3).isEmpty)
  }

  // hub-action.registrar.ts:96-100
  @Test func shouldFinalizeTheApprovedChapter() async throws {
    let book = try await StagingWorld.workspace()
    try await book.approve(3)
    try await book.reviewRead(3)
    let id = try await book.stage(World.finalize3).proposal.id
    let outcome = try only(try await book.applied(id, .indexes([0])), 0)
    #expect(outcome.status == .applied)
    #expect(outcome.summary == "finalized chapter 3")
    #expect(try await book.final(3) != nil)
  }

  // proposal-apply.service.ts:249-282: actions run in index order, one failure skips the rest, and the content stays applied
  @Test func shouldSkipTheActionsAfterOneThatFailedAndKeepTheContent() async throws {
    let book = try await StagingWorld.workspace()
    try await volumes(book)
    let id = try await book.stage(World.kael, World.finalize3, World.advance("volume_1")).proposal.id
    let outcomes = try await book.applied(id, .indexes([0, 1, 2]))
    #expect(outcomes.map(\.status) == [.applied, .failed, .failed])
    #expect(outcomes[1].failure == ProposalChangeFailure(.domain(.draftNotApproved(3))))
    #expect(outcomes[2].failure == .previousActionFailed)
    #expect(try await book.change(id, 2).actionOutcome == .known(.failed))
    #expect(try await book.entity("kael") != nil)
    #expect(try await book.activeVolume() == "volume_1")
    #expect(try await book.final(3) == nil)
  }

  // volume-action.registrar.ts:17-24
  @Test func shouldCompleteTheActiveVolumeAndStartTheNext() async throws {
    let book = try await StagingWorld.workspace()
    try await volumes(book)
    let id = try await book.stage(World.advance("volume_1")).proposal.id
    let outcome = try only(try await book.applied(id, .indexes([0])), 0)
    #expect(outcome.summary == "volume volume_1's goal is met — volume volume_2 is now active")
    #expect(try await book.activeVolume() == "volume_2")
  }

  // RULES F11a (7): the active volume is found again inside the action's transaction (VOL_003)
  @Test func shouldRefuseToCompleteAVolumeThatIsNoLongerActive() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    try await volumes(book)
    let id = try await book.stage(World.advance("volume_1")).proposal.id
    try await book.run { _ = try Volumes.markGoalMet(novel: novel, volume: "volume_1", in: &$0) }
    let outcome = try only(try await book.applied(id, .indexes([0])), 0)
    #expect(outcome.failure == ProposalChangeFailure(.domain(.volumeNotActive("volume_1"))))
    #expect(try await book.activeVolume() == "volume_2")
  }

  // RULES F11a (3): a volume this device cannot read may be the active one, so none is completed
  @Test func shouldRefuseToCompleteAVolumeWhileAnotherVolumeCannotBeRead() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    try await volumes(book)
    let id = try await book.stage(World.advance("volume_1")).proposal.id
    let ghost = NovelForgeKey.volumeKey(novel: novel, volume: "volume_0")
    try await book.run { transaction in _ = try transaction.set(ghost.ref, ["natural_key": ghost.stored, "removed": .bool(false)]) }
    let outcome = try only(try await book.applied(id, .indexes([0])), 0)
    #expect(outcome.failure == ProposalChangeFailure(.refused(.unreadableReferences(kind: "volume", count: 1))))
    #expect(try await book.activeVolume() == "volume_1")
  }

  // RULES F10: an apply interrupted after its content committed runs its pending actions once, read through `actionOutcome`
  @Test func shouldResumeThePendingActionsOfAnInterruptedApplyOnce() async throws {
    let book = try await StagingWorld.workspace()
    let head = try #require(try await book.head(3))
    let id = try await book.stage(World.kael, World.approve3).proposal.id
    let context = book.context()
    let outcome = try await book.run { try ProposalApply.apply(proposal: id, selection: .indexes([0, 1]), context: context, in: &$0) }
    #expect(outcome == .applied([ProposalChangeOutcome(index: 0, status: .applied, source: nil), ProposalChangeOutcome(index: 1, status: .pending, source: nil)]))
    #expect(try await book.change(id, 1).actionOutcome == .known(.pending))
    #expect(try await book.approvals(3).isEmpty)

    let resumed = try await book.store.resumeProposalActions(id, novel: book.novel)
    #expect(resumed == [ProposalActionResult(index: 1, outcome: .known(.applied), summary: "approved chapter 3's draft")])
    #expect(try await book.store.resumeProposalActions(id, novel: book.novel) == [ProposalActionResult(index: 1, outcome: .known(.applied))])
    #expect(try await book.approvals(3).map(\.draftRevision) == [head])
  }

  // RULES F10: a settled action never runs again, even once it would now succeed
  @Test func shouldNeverRunAgainAnActionThatSettledAsFailed() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(World.finalize3).proposal.id
    #expect(try await book.applied(id, .indexes([0])).map(\.status) == [.failed])
    try await book.approve(3)
    #expect(try await book.store.resumeProposalActions(id, novel: book.novel) == [ProposalActionResult(index: 0, outcome: .known(.failed))])
    #expect(try await book.final(3) == nil)
  }

  // A resumed approval beside the card's own edit is refused over unsaved edits made over the head that edit wrote
  @Test func shouldRefuseAResumedApprovalOverUnsavedEditsOnTheHeadTheCardsEditWrote() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#, World.approve3).proposal.id
    let context = book.context()
    _ = try await book.run { try ProposalApply.apply(proposal: id, selection: .indexes([0, 1]), context: context, in: &$0) }
    let written = try #require(try await book.head(3))
    try await book.save(3, "Mine.\n\n\(Text.body)", title: "The Bout", summary: "It turns.", base: written)
    let resumed = try await book.store.resumeProposalActions(id, novel: book.novel)
    #expect(resumed.map(\.failure) == [ProposalChangeFailure(.domain(.draftConflict(chapter: 3, head: written)))])
    #expect(try await book.approvals(3).isEmpty)
  }

  // proposal-apply.service.ts:263-266: a resume after an action settled as failed skips the rest
  @Test func shouldSkipThePendingActionsAfterOneSettledAsFailedOnResume() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    let id = try await book.stage(World.finalize3, World.approve3).proposal.id
    let context = book.context()
    _ = try await book.run { try ProposalApply.apply(proposal: id, selection: .indexes([0, 1]), context: context, in: &$0) }
    let failure = ProposalChangeFailure(code: "DRF_004", message: "not approved")
    _ = try await book.run { try ProposalApply.failAction(proposal: id, index: 0, novel: novel, failure: failure, in: &$0) }
    let resumed = try await book.store.resumeProposalActions(id, novel: novel)
    #expect(resumed == [ProposalActionResult(index: 0, outcome: .known(.failed)), ProposalActionResult(index: 1, outcome: .known(.failed), failure: .previousActionFailed)])
    #expect(try await book.approvals(3).isEmpty)
  }

  // An action this version cannot run stays pending for a device that can, and the actions after it wait with it
  @Test func shouldLeaveEveryActionFromOneThisVersionCannotRunPendingOnResume() async throws {
    let book = try await StagingWorld.workspace()
    let proposal = try await book.stage(#"{"op":"action.validate","scope":"novel"}"#, World.approve3).proposal
    try await book.run { transaction in
      let changes = try [0, 1].map { try ProposalChangeRecord(novel: proposal.novel, proposal: proposal.id, index: $0, status: .pending) }
      _ = try ProposalRecord.recordApply(proposal.ref, changes: changes, postState: ArtifactStates(), automatic: false, in: &transaction)
    }
    #expect(try await book.store.resumeProposalActions(proposal.id, novel: book.novel).isEmpty)
    #expect(try await book.change(proposal.id, 1).actionOutcome == .known(.pending))
    #expect(try await book.approvals(3).isEmpty)
  }

  // An action change this device cannot read may be an action that has to run first, so nothing after it runs
  @Test func shouldStopResumingAtAnActionChangeThisDeviceCannotRead() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    let id = try await book.stage(World.finalize3, World.approve3).proposal.id
    let context = book.context()
    _ = try await book.run { try ProposalApply.apply(proposal: id, selection: .indexes([0, 1]), context: context, in: &$0) }
    let ref = try ProposalChangeRecord.ref(novel: novel, proposal: id, index: 0)
    try await book.run { transaction in _ = try transaction.set(ref, [ProposalChangeField.result.rawValue: .int(1)]) }
    guard case .unreadable = try await book.changes(id)[0] else {
      Issue.record("the corrupted change still reads")
      return
    }
    #expect(try await book.store.resumeProposalActions(id, novel: novel).isEmpty)
    #expect(try await book.change(id, 1).actionOutcome == .known(.pending))
    #expect(try await book.approvals(3).isEmpty)
  }

  // N3: a store failure under an action after the content committed leaves it and the actions after it pending, reported, never thrown; a resume runs them
  @Test func shouldLeaveTheActionsPendingWhenTheStoreFailsAfterTheContentCommitted() async throws {
    let book = try await StagingWorld.workspace()
    try await book.reviewRead(3)
    let id = try await book.stage(World.kael, World.approve3, World.finalize3).proposal.id
    try await book.run { transaction in
      try transaction.database.execute(sql: "DROP TABLE IF EXISTS nf_local_draft_working_copy")
      try transaction.database.execute(sql: "CREATE TABLE nf_local_draft_working_copy (novel BLOB, chapter INTEGER)")
    }
    let outcomes = try await book.applied(id, .indexes([0, 1, 2]))
    #expect(outcomes.map(\.status) == [.applied, .pending, .pending])
    #expect(outcomes[1].failure?.code == "store.database")
    #expect(outcomes[2].failure == nil)
    #expect(try await book.entity("kael") != nil)
    #expect(try await book.change(id, 1).actionOutcome == .known(.pending))
    #expect(try await book.change(id, 2).actionOutcome == .known(.pending))
    try await book.run { transaction in try transaction.database.execute(sql: "DROP TABLE nf_local_draft_working_copy") }
    let resumed = try await book.store.resumeProposalActions(id, novel: book.novel)
    #expect(resumed.map(\.outcome) == [.known(.applied), .known(.applied)])
    #expect(try await book.final(3) != nil)
  }

  // RULES F02/F10: a second applier's `pending` written over a settled result never makes the action run again
  @Test func shouldNeverRunAgainAnActionWhosePendingStatusWasWrittenOverItsResult() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    let id = try await book.stage(World.finalize3).proposal.id
    #expect(try await book.applied(id, .indexes([0])).map(\.status) == [.failed])
    try await book.approve(3)
    let ref = try ProposalChangeRecord.ref(novel: novel, proposal: id, index: 0)
    try await book.run { transaction in _ = try transaction.set(ref, [ProposalChangeField.status.rawValue: StoredEnum.known(ProposalChangeStatus.pending).json]) }
    #expect(try await book.change(id, 0).status == .known(.pending))
    #expect(try await book.store.resumeProposalActions(id, novel: novel) == [ProposalActionResult(index: 0, outcome: .known(.failed))])
    #expect(try await book.final(3) == nil)
  }

  // A resumed approval beside the card's own edit binds the head that edit left, read from the edit's stored undo
  @Test func shouldBindAResumedApprovalToTheHeadTheCardsEditLeft() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#, World.approve3).proposal.id
    let context = book.context()
    _ = try await book.run { try ProposalApply.apply(proposal: id, selection: .indexes([0, 1]), context: context, in: &$0) }
    let written = try #require(try await book.head(3))
    #expect(try await book.store.resumeProposalActions(id, novel: book.novel).map(\.outcome) == [.known(.applied)])
    #expect(try await book.approvals(3).map(\.draftRevision) == [written])

    let moved = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout Again"}"#, World.approve3, session: nil).proposal.id
    _ = try await book.run { try ProposalApply.apply(proposal: moved, selection: .indexes([0, 1]), context: context, in: &$0) }
    try await book.reviseElsewhere(3, "Theirs.\n\n\(Text.body)")
    let resumed = try await book.store.resumeProposalActions(moved, novel: book.novel)
    #expect(resumed.map(\.failure?.code) == ["DRF_013"])
  }
}
