import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private typealias World = RevertWorld

extension ChapterBook {
  fileprivate func milestones() async throws -> [String] {
    let novel = novel
    return try await store.read { try MilestoneRecord.listing(novel: novel, in: $0).live.map(\.milestone) }
  }

  fileprivate func handEditMara(_ notes: String) async throws {
    let novel = novel
    try await run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(notes: notes), in: &$0) }
  }
}

// apps/novel-forge-server/tests/refinement/proposal-apply-op-undo.spec.ts over proposal-revert.service.ts and proposal-op-undo.service.ts
@Suite("Proposal revert", .timeLimit(.minutes(3)))
struct ProposalRevertTests {
  // proposal-apply-op-undo.spec.ts:105
  @Test func shouldUndoOneChangeAndLeaveTheRestOfTheTurnApplied() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)

    let toggle = try await book.undoChange(id, 2)

    #expect(toggle.changed && toggle.source == .quoted && toggle.rejection == nil && toggle.refs == ["entity:mara"])
    let mara = try #require(try await book.entity("mara"))
    #expect(mara.notes == "Mara hides the slip." && mara.motivation == nil)
    #expect(try await book.entity("kael") != nil)
    #expect(try await book.milestones().contains("kael-escapes"))
    #expect(try await book.statuses(id) == [.applied, .applied, .reverted])
    let change = try await book.change(id, 2)
    #expect(change.undoneState == ArtifactStates(try await book.states(["entity:mara"])))
  }

  // proposal-apply-op-undo.spec.ts:120
  @Test func shouldRedoAnUndoneChange() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    try await book.undoChange(id, 2)

    #expect(try await book.redoChange(id, 2).changed)

    #expect(try await book.entity("mara")?.notes == "Mara keeps the slip in her boot.")
    #expect(try await book.statuses(id) == [.applied, .applied, .applied])
  }

  // proposal-apply-op-undo.spec.ts:132 (RFN_015)
  @Test func shouldRefuseToUndoAChangeAnotherAppliedChangeReliesOnAndWriteNothing() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)

    let refusal = await book.undoRefusal(id, 0)

    #expect(refusal == .dependents(index: 0, [1]))
    #expect(refusal?.code == "RFN_015")
    #expect(try await book.entity("kael") != nil)
    #expect(try await book.statuses(id) == [.applied, .applied, .applied])
  }

  // proposal-apply-op-undo.spec.ts:144 (RFN_016)
  @Test func shouldUndoADependentFirstAndRedoOnlyInTheOppositeOrder() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)

    try await book.undoChange(id, 1)
    try await book.undoChange(id, 0)
    #expect(try await book.entity("kael") == nil)
    #expect(try await book.milestones().contains("kael-escapes") == false)

    let refusal = await book.redoRefusal(id, 1)
    #expect(refusal == .prerequisites(index: 1, [0]))
    #expect(refusal?.code == "RFN_016")
    try await book.redoChange(id, 0)
    try await book.redoChange(id, 1)
    let milestone = try await book.store.read { [novel = book.novel] in
      try MilestoneRecord.listing(novel: novel, in: $0).live.first { $0.milestone == "kael-escapes" }
    }
    #expect(milestone?.subject == "kael")
  }

  // proposal-apply-op-undo.spec.ts:159
  @Test func shouldTreatARepeatedUndoOrRedoAsDoneWritingNothing() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    try await book.undoChange(id, 2)
    let before = try await book.store.pendingChanges(limit: .max).count

    #expect(try await book.undoChange(id, 2).changed == false)
    #expect(try await book.store.pendingChanges(limit: .max).count == before)
    try await book.redoChange(id, 2)
    let redone = try await book.store.pendingChanges(limit: .max).count
    #expect(try await book.redoChange(id, 2).changed == false)
    #expect(try await book.store.pendingChanges(limit: .max).count == redone)
  }

  // proposal-apply-op-undo.spec.ts:171-184: the rest of the turn reverts as a whole; a redo afterwards stays possible (F02: RFN_017 is not reached)
  @Test func shouldRevertTheRestOfTheTurnAsAWholeAfterOneChangeWasUndoneOnItsOwn() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    try await book.undoChange(id, 2)

    let result = try await book.revertCard(id)

    #expect(result.reverted == [0, 1])
    #expect(try await book.entity("kael") == nil)
    #expect(try await book.milestones().contains("kael-escapes") == false)
    #expect(try await book.entity("mara")?.notes == "Mara hides the slip.")
    #expect(try await book.statuses(id) == [.reverted, .reverted, .reverted])
    #expect(try await book.undoChange(id, 0).changed == false)
    #expect(await book.revertRefusal(id) == .notRevertible)
    #expect(try await book.redoChange(id, 2).changed)
    #expect(try await book.entity("mara")?.notes == "Mara keeps the slip in her boot.")
  }

  // proposal-apply-op-undo.spec.ts:186
  @Test func shouldEmptyAFieldTheTurnFilledWhenTheWholeTurnIsReverted() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    #expect(try await book.entity("mara")?.motivation == "She wants the ledger back.")

    try await book.revertCard(id)

    let mara = try #require(try await book.entity("mara"))
    #expect(mara.notes == "Mara hides the slip." && mara.motivation == nil)
  }

  // proposal-apply-op-undo.spec.ts:217-236: the Notebook write runs only when the change moved
  @Test func shouldTurnAnUndoneIdeaDownAndWithdrawItOnRedoOnlyWhenTheChangeMoved() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)

    let undone = try await book.undoChange(id, 1, idea: IdeaUndoChoice(scope: .never, why: "Kael escapes later."))
    #expect(undone.source == .idea)
    let rejection = try #require(undone.rejection)
    #expect(rejection.rejectionScope == .known(.never))
    #expect(try await book.undoChange(id, 1).rejection == nil)

    let redone = try await book.redoChange(id, 1)
    #expect(redone.withdrawals.count == 1)
    #expect(try await book.redoChange(id, 1).withdrawals.isEmpty)
  }

  // proposal-apply-op-undo.spec.ts:228: an undo after the whole turn was reverted is done, with no Notebook write
  @Test func shouldTreatAnUndoAfterAWholeRevertAsDoneWithNoRejection() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    try await book.revertCard(id)

    let toggle = try await book.undoChange(id, 0)

    #expect(toggle.changed == false && toggle.source == .idea && toggle.rejection == nil)
  }

  // proposal-apply-op-undo.spec.ts:238 (RFN_003)
  @Test func shouldRefuseToRedoAChangeWhoseRecordMovedOnSinceItWasUndone() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    try await book.undoChange(id, 2)
    try await book.handEditMara("The author rewrote this by hand.")

    let refusal = await book.redoRefusal(id, 2)

    #expect(refusal?.code == "RFN_003")
    guard case .redoConflicted(let mismatches) = refusal else { throw RevertTestError.unexpected }
    #expect(mismatches.map(\.ref) == ["entity:mara"] && mismatches.first?.indexes == [2])
    let mara = try #require(try await book.entity("mara"))
    #expect(mara.notes == "The author rewrote this by hand." && mara.motivation == nil)
  }

  // proposal-apply-op-undo.spec.ts:248 (RFN_006)
  @Test func shouldRefuseToUndoAChangeWhoseRecordMovedOnSinceTheTurnAppliedIt() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    try await book.handEditMara("The author rewrote this by hand.")

    #expect(await book.undoRefusal(id, 2)?.code == "RFN_006")
    #expect(await book.revertRefusal(id)?.code == "RFN_006")
    #expect(try await book.entity("mara")?.notes == "The author rewrote this by hand.")
    #expect(try await book.entity("kael") != nil)
    #expect(try await book.statuses(id) == [.applied, .applied, .applied])
  }

  // proposal-apply-op-undo.spec.ts:257 and :264 (RFN_014)
  @Test func shouldRefuseAPerChangeUndoOfACardTheAuthorAppliedOrOfAnotherKind() async throws {
    let (book, id) = try await World.turn()
    _ = try await book.applied(id)
    #expect(await book.undoRefusal(id, 2) == .notToggleable(index: 2))
    #expect(await book.redoRefusal(id, 2)?.code == "RFN_014")

    let (extract, other) = try await World.turn(kind: .chapterExtract)
    try await extract.applyTurn(other)
    #expect(await extract.undoRefusal(other, 2)?.code == "RFN_014")
    #expect(try await extract.revertCard(other).reverted == [2, 0, 1])
  }

  // proposal-apply-op-undo.spec.ts:271 (RFN_001) and :278 (RFN_011)
  @Test func shouldNotFindAnotherNovelsTurnAndRefuseAnIndexOutsideTheChangeSet() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    let other = ProposalRevertContext(novel: SchemaFixture.otherNovel, now: book.clock.now)
    do {
      _ = try await book.store.undoProposalChange(id, index: 2, context: other)
      Issue.record("another novel's turn was undone")
    } catch {
      #expect(error == .notFound(id))
    }
    #expect(await book.undoRefusal(id, 3) == .invalidIndex(3))
    #expect(await book.undoRefusal(UUID(), 0)?.code == "RFN_001")
  }

  // proposal-revert.service.ts:94, :137 (RFN_007) and :171 (RFN_017): nothing is undone or redone on a card that is not applied
  @Test func shouldRefuseAToggleOrRevertOfACardThatIsNotApplied() async throws {
    let (book, id) = try await World.turn()
    #expect(await book.undoRefusal(id, 0) == .notRevertible)
    #expect(await book.redoRefusal(id, 0) == .turnNotApplied)
    #expect(await book.revertRefusal(id) == .notRevertible)
  }

  // proposal-revert.service.ts:150-154 (RFN_018): the undo is refused when the inverse does not land on the state the apply found
  @Test func shouldRefuseAnUndoThatCannotPutTheRecordsBackExactly() async throws {
    let (book, id) = try await World.turn()
    let novel = book.novel
    let now = book.clock.now
    try await book.run { transaction in
      let proposal = try ProposalApply.pending(id, novel: novel, in: transaction)
      let op = try #require(proposal.card.ops[2])
      let step = try ApplyFrame.perform(.op(op), context: ApplyContext(novel: novel, intent: .apply, now: now), in: &transaction)
      var prior = step.priorState
      prior[JSString("entity:mara")] = ArtifactState(exists: true, revision: nil, contentHash: "not what the undo leaves")
      let undo = try ProposalChangeUndo(inverse: try #require(step.inverse), priorState: ArtifactStates(prior), postState: ArtifactStates(step.postState))
      let change = try ProposalChangeRecord(novel: novel, proposal: id, index: 2, status: .applied, undo: undo)
      _ = try ProposalRecord.recordApply(
        proposal.ref, changes: [change], postState: ArtifactStates(step.postState), sources: RevertWorld.sources.map(StoredEnum.known), automatic: true, in: &transaction)
    }

    #expect(await book.undoRefusal(id, 2) == .inverseDidNotRestore(index: 2))
    #expect(await book.undoRefusal(id, 2)?.code == "RFN_018")
    #expect(try await book.entity("mara")?.notes == "Mara keeps the slip in her boot.")
  }

  // A change the first applier left out, whose records still stand as the card's baseline, never applied: it relies on nothing being kept
  @Test func shouldUndoAChangeWhoseDeclinedDependentIsConfirmedAbsent() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id, .indexes([0]))
    #expect(try await book.changes(id)[1] == .declined)

    #expect(try await book.undoChange(id, 0).changed)
    #expect(try await book.entity("kael") == nil)
  }

  // A declined change whose record moved since staging may be a concurrent applier's whose record has not arrived; by default the undo refuses
  @Test func shouldRefuseAnUndoWhileADeclinedDependentsContentIsPresent() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id, .indexes([0]))
    let novel = book.novel
    try await book.run { try Milestones.create(novel: novel, milestone: "kael-escapes", label: "Kael escapes", subject: "kael", in: &$0) }

    #expect(await book.undoRefusal(id, 0) == .declinedChanged([1]))
    #expect(await book.revertRefusal(id) == .declinedChanged([1]))
    #expect(try await book.entity("kael") != nil)
  }

  // The author's own record over a declined change's key never blocks for good: once they accept it as never applied, the card reverts
  @Test func shouldRevertOverAChangedDeclinedIndexOnceTheAuthorAcceptsIt() async throws {
    let (book, id) = try await World.turn()
    _ = try await book.applied(id, .indexes([0]))
    let novel = book.novel
    try await book.run { try Milestones.create(novel: novel, milestone: "kael-escapes", label: "Mara escapes", subject: "mara", in: &$0) }

    let refusal = await book.revertRefusal(id)
    #expect(refusal == .declinedChanged([1]))
    #expect(refusal?.code == "refinement.declined_changed")
    var accepting = book.revertContext
    accepting.acceptingChangedDeclined = [1]
    #expect(try await book.store.revertProposal(id, context: accepting).reverted == [0])
    #expect(try await book.entity("kael") == nil)
    #expect(try await book.milestones().contains("kael-escapes"))
  }

  // MIL_003 through an undo and a whole revert: a milestone the turn created that a written plan now claims is not removed, and nothing is written
  @Test func shouldRefuseToUndoAMilestoneAWrittenPlanNowClaims() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    try await book.plan(4, claims: ["kael-escapes"])

    let refusal = await book.undoRefusal(id, 1)
    #expect(refusal?.code == "MIL_003")
    guard case .apply(let index, .domain(.milestoneReferenced(let milestone, _))) = refusal else { throw RevertTestError.unexpected }
    #expect(index == 1 && milestone == "kael-escapes")
    #expect(await book.revertRefusal(id)?.code == "MIL_003")
    #expect(try await book.milestones().contains("kael-escapes"))
    #expect(try await book.entity("mara")?.notes == "Mara keeps the slip in her boot.")
    #expect(try await book.statuses(id) == [.applied, .applied, .applied])
  }

  // proposal-revert.service.ts:100-107: a whole revert's conflict lists every record that moved, not only the first
  @Test func shouldListEveryMovedRecordWhenAWholeRevertConflicts() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    try await book.handEditMara("The author rewrote this by hand.")
    let novel = book.novel
    try await book.run { try Entities.edit(novel: novel, entity: "kael", EntityDetails(notes: "Edited by hand."), in: &$0) }

    guard case .conflicted(let mismatches) = await book.revertRefusal(id) else { throw RevertTestError.unexpected }
    #expect(Set(mismatches.map(\.ref)) == ["entity:mara", "entity:kael"])
    #expect(Set(mismatches.flatMap(\.indexes)) == [0, 2])
  }

  // proposal-op-undo.service.ts:23: an undone idea is turned down `not_now` unless the author chose a scope
  @Test func shouldTurnAnUndoneIdeaDownForNowByDefault() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)

    let rejection = try #require(try await book.undoChange(id, 1).rejection)

    #expect(rejection.rejectionScope == .known(.notNow) && rejection.why == nil)
  }

  // proposal-revert.service.ts:183-185 deviation: a redo that would land elsewhere than the apply did (an ordinal-less volume placed after one created since)
  // is refused, since the change could not be undone again
  @Test func shouldRefuseARedoThatLandsOnAnotherOrdinal() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    let id = try await book.stage(#"{"op":"volume.upsert","volumeKey":"volume_9","title":"Nine"}"#, kind: .chat).proposal.id
    try await book.applyTurn(id, sources: [.quoted])
    try await book.undoChange(id, 0)
    try await book.run { try Volumes.create(novel: novel, volume: "volume_10", title: "Ten", in: &$0) }

    let refusal = await book.redoRefusal(id, 0)
    #expect(refusal == .redoDidNotRestore(index: 0))
    #expect(try await book.statuses(id) == [.reverted])
  }

  @Test func shouldRefuseARedoThatDoesNotLandWhereTheApplyLeftTheRecords() async throws {
    let (book, id) = try await RevertWorld.turn()
    let novel = book.novel
    let now = book.clock.now
    try await book.run { transaction in
      let proposal = try ProposalApply.pending(id, novel: novel, in: transaction)
      let op = try #require(proposal.card.ops[2])
      let step = try ApplyFrame.perform(.op(op), context: ApplyContext(novel: novel, intent: .apply, now: now), in: &transaction)
      let inverse = try #require(step.inverse)
      _ = try BibleHandlers.undo(inverse, context: ApplyContext(novel: novel, intent: .undo, now: now), in: &transaction)
      var post = step.postState
      post[JSString("entity:mara")] = ArtifactState(exists: true, revision: nil, contentHash: "not what the redo leaves")
      let undo = try ProposalChangeUndo(inverse: inverse, priorState: ArtifactStates(step.priorState), postState: ArtifactStates(post))
      let change = try ProposalChangeRecord(novel: novel, proposal: id, index: 2, status: .applied, undo: undo)
      _ = try ProposalRecord.recordApply(
        proposal.ref, changes: [change], postState: ArtifactStates(post), sources: RevertWorld.sources.map(StoredEnum.known), automatic: true, in: &transaction)
      let ref = try ProposalChangeRecord.ref(novel: novel, proposal: id, index: 2)
      _ = try ProposalChangeRecord.recordUndo(ref, undoneState: ArtifactStates(step.priorState), in: &transaction)
    }

    #expect(await book.redoRefusal(id, 2) == .redoDidNotRestore(index: 2))
    #expect(try await book.entity("mara")?.notes == "Mara hides the slip.")
    #expect(try await book.statuses(id) == [nil, nil, .reverted])
  }

  @Test func shouldRefuseAWholeRevertWhileAChangeAwaitsItsRecord() async throws {
    let (book, id) = try await RevertWorld.turn()
    let novel = book.novel
    let now = book.clock.now
    try await book.run { transaction in
      let proposal = try ProposalApply.pending(id, novel: novel, in: transaction)
      let op = try #require(proposal.card.ops[0])
      let step = try ApplyFrame.perform(.op(op), context: ApplyContext(novel: novel, intent: .apply, now: now), in: &transaction)
      let undo = try ProposalChangeUndo(inverse: try #require(step.inverse), priorState: ArtifactStates(step.priorState), postState: ArtifactStates(step.postState))
      _ = try ProposalChangeRecord(novel: novel, proposal: id, index: 0, status: .applied, undo: undo).create(in: &transaction)
      let application = ProposalApplication(selected: [0, 2], postState: ArtifactStates(step.postState), automatic: false)
      _ = try transaction.set(
        proposal.ref, [ProposalField.decision.rawValue: StoredEnum.known(ProposalDecision.applied).json, ProposalField.applied.rawValue: application.json])
    }
    #expect(try await book.changes(id)[2] == .awaiting)

    #expect(await book.revertRefusal(id) == .changesNotSynced([2]))
    #expect(try await book.entity("kael") != nil)
  }

  // DraftHandlers.settleWorkingCopies before an undo's guard: a rewrite a concurrent author applied beside an automatic first applier toggles on its own,
  // and unsaved edits over it are committed first, so the guard sees them and refuses
  @Test func shouldSettleTheWorkingCopyBeforeTheGuardOfADraftUndo() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(StagingText.rewrite(StagingText.fear, StagingText.fearRewrite), kind: .chat).proposal.id
    let novel = book.novel
    let now = book.clock.now
    try await book.run { transaction in
      let proposal = try ProposalApply.pending(id, novel: novel, in: transaction)
      let op = try #require(proposal.card.ops[0])
      let step = try ApplyFrame.perform(.op(op), context: ApplyContext(novel: novel, intent: .apply, now: now), in: &transaction)
      let undo = try ProposalChangeUndo(inverse: try #require(step.inverse), priorState: ArtifactStates(step.priorState), postState: ArtifactStates(step.postState))
      let change = try ProposalChangeRecord(novel: novel, proposal: id, index: 0, status: .applied, undo: undo)
      _ = try ProposalRecord.recordApply(proposal.ref, changes: [change], postState: ArtifactStates(step.postState), sources: [.known(.quoted)], automatic: true, in: &transaction)
    }
    let head = try #require(try await book.head(3))
    var content = try #require(try await book.draftContent(3))
    content.body += "\n\nMine."
    try await book.run { [content] transaction in try DraftWorkingCopy(novel: novel, chapter: 3, base: head, content: content).save(in: transaction.database) }

    #expect(await book.undoRefusal(id, 0)?.code == "RFN_006")
    #expect(try await book.workingCopy(3) != nil)
    #expect(try await book.draftContent(3)?.body.contains(StagingText.fearRewrite) == true)
  }

  // apply-rules.ts:46-51 through a whole revert: restoring a plan's claim on a milestone a later plan now claims breaks the plan rule (PLN_003)
  @Test func shouldRefuseAWholeRevertThatBreaksAPlanRule() async throws {
    let (book, turn) = try await RevertWorld.turn()
    try await book.applyTurn(turn)
    try await book.plan(4, claims: ["kael-escapes"])
    let id = try await book.stage(#"{"op":"brief.update","chapter":4,"claimedMilestones":[]}"#, session: nil).proposal.id
    _ = try await book.applied(id)
    try await book.plan(5, claims: ["kael-escapes"])

    let refusal = await book.revertRefusal(id)

    guard case .domain(.planClaims(let chapter, _)) = refusal else { throw RevertTestError.unexpected }
    #expect(chapter == 4)
    #expect(refusal?.code == "PLN_003")
  }

  // proposal-revert.service.ts:111: two changes to one record revert latest first, each over the state the other left
  @Test func shouldRevertTwoChangesOnOneRecordLatestFirst() async throws {
    let (book, _) = try await RevertWorld.turn()
    let id = try await book.stage(RevertWorld.maraNotes, ApplyWorld.maraMotive, session: nil).proposal.id
    _ = try await book.applied(id)

    #expect(try await book.revertCard(id).reverted == [1, 0])
    #expect(try await book.entity("mara")?.notes == "Mara hides the slip.")
  }

  // A declined change that writes only a record the reverted change's own guard covers needs no absence check
  @Test func shouldRevertBesideADeclinedChangeOnTheSameRecord() async throws {
    let (book, _) = try await RevertWorld.turn()
    let id = try await book.stage(RevertWorld.maraNotes, ApplyWorld.maraMotive, session: nil).proposal.id
    _ = try await book.applied(id, .indexes([0]))

    #expect(try await book.revertCard(id).reverted == [0])
  }

  // An apply with a change this device cannot read is listed, so its revert refuses and stops the rollback; it is never skipped past
  @Test func shouldStopARollbackAtAnApplyWithAChangeThisDeviceCannotRead() async throws {
    let book = try await StagingWorld.workspace()
    let anchor = try await book.stage(ApplyWorld.premise, session: nil).proposal.id
    _ = try await book.applied(anchor)
    let later = try await book.stage(RevertWorld.maraNotes, session: nil).proposal.id
    _ = try await book.applied(later)
    let novel = book.novel
    try await book.run { transaction in
      _ = try transaction.set(try ProposalChangeRecord.ref(novel: novel, proposal: later, index: 0), [ProposalChangeField.status.rawValue: .int(5)])
    }

    let result = try await book.store.rollbackProposals(after: anchor, context: book.revertContext)

    #expect(result.reverted.isEmpty && result.skipped.isEmpty)
    #expect(result.stoppedAt == later && result.conflict == .changeUnreadable(index: 0))
    #expect(try await book.entity("mara")?.motivation == "She wants the ledger back.")
  }

  // proposal-apply.service.ts:65-71: an action is a one-way door; a whole revert leaves it and undoes the content
  @Test func shouldLeaveAnAppliedActionStandingWhenTheCardIsReverted() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(ApplyWorld.premise, ApplyWorld.approve3).proposal.id
    let head = try #require(try await book.head(3))
    _ = try await book.applied(id, .indexes([0, 1]))
    #expect(try await book.approvals(3).map(\.draftRevision) == [head])

    #expect(try await book.revertCard(id).reverted == [0])

    #expect(try await book.premise() == nil)
    #expect(try await book.approvals(3).map(\.draftRevision) == [head])
    #expect(try await book.change(id, 1).actionOutcome == .known(.applied))
  }

  // An unreadable change may hold an undo: it is refused and shown, never skipped, by a toggle and by a whole revert
  @Test func shouldRefuseAChangeThisDeviceCannotRead() async throws {
    let (book, id) = try await World.turn()
    try await book.applyTurn(id)
    let novel = book.novel
    try await book.run { transaction in
      _ = try transaction.set(try ProposalChangeRecord.ref(novel: novel, proposal: id, index: 2), [ProposalChangeField.status.rawValue: .int(5)])
    }

    #expect(await book.undoRefusal(id, 2) == .changeUnreadable(index: 2))
    #expect(await book.revertRefusal(id) == .changeUnreadable(index: 2))
    #expect(try await book.undoChange(id, 1).changed)
  }

  // proposal-revert.service.ts:271-311: later applies revert newest first, one transaction each; an action-only apply is skipped, a reverted one (a declined
  // index beside it) is not listed, and the first refusal stops it
  @Test func shouldRollBackLaterAppliesNewestFirstAndStopAtTheFirstConflict() async throws {
    let book = try await StagingWorld.workspace()
    let anchor = try await book.stage(ApplyWorld.premise, session: nil).proposal.id
    _ = try await book.applied(anchor)
    let page = #"{"op":"bible_document.upsert","section":"world","slug":"salle","body":"Chalk and bars of light."}"#
    let undone = try await book.stage(page, ApplyWorld.kael, session: nil).proposal.id
    _ = try await book.applied(undone, .indexes([0]))
    try await book.revertCard(undone)
    let first = try await book.stage(RevertWorld.kael, session: nil).proposal.id
    _ = try await book.applied(first)
    let action = try await book.stage(ApplyWorld.approve3, session: nil).proposal.id
    _ = try await book.applied(action, .indexes([0]))
    let last = try await book.stage(RevertWorld.maraNotes, session: nil).proposal.id
    _ = try await book.applied(last)

    let stopped = try await book.store.rollbackProposals(after: anchor, context: book.revertContext)
    #expect(stopped.reverted.map(\.proposal) == [last, first] && stopped.skipped == [action] && stopped.stoppedAt == nil)
    #expect(try await book.entity("kael") == nil)
    #expect(try await book.entity("mara")?.motivation == nil)
    #expect(try await book.premise() == "A fencer keeps a lamp.")

    let again = try await book.stage(RevertWorld.kael, session: nil).proposal.id
    _ = try await book.applied(again)
    let later = try await book.stage(RevertWorld.maraNotes, session: nil).proposal.id
    _ = try await book.applied(later)
    let novel = book.novel
    try await book.run { try Entities.edit(novel: novel, entity: "kael", EntityDetails(notes: "Edited by hand."), in: &$0) }
    let conflict = try await book.store.rollbackProposals(after: anchor, context: book.revertContext)
    #expect(conflict.reverted.map(\.proposal) == [later] && conflict.stoppedAt == again && conflict.conflict?.code == "RFN_006")
    #expect(try await book.entity("kael")?.notes == "Edited by hand.")
  }

  // F02 rule: inverses are content-based, so apply, undo, redo and undo again land on the content hashes the apply found and left
  @Test func shouldRestoreTheContentHashesThroughUndoRedoUndo() async throws {
    let book = try await StagingWorld.workspace()
    let page = #"{"op":"bible_document.upsert","section":"world","slug":"salle","body":"Chalk and bars of light."}"#
    let id = try await book.stage(RevertWorld.kael, ApplyWorld.premise, page, kind: .chat).proposal.id
    let refs = ["entity:kael", "premise", "doc:world/salle"]
    let before = try await book.states(refs)
    try await book.applyTurn(id, sources: [.quoted, .quoted, .quoted])
    let after = try await book.states(refs)
    #expect(after != before)

    for index in [0, 1, 2] { try await book.undoChange(id, index) }
    #expect(try await book.states(refs) == before)
    for index in [0, 1, 2] { try await book.redoChange(id, index) }
    #expect(try await book.states(refs) == after)
    for index in [2, 1, 0] { try await book.undoChange(id, index) }
    #expect(try await book.states(refs) == before)
    try await book.redoChange(id, 1)
    #expect(try await book.revertCard(id).reverted == [1])
    #expect(try await book.states(refs) == before)
  }

  // proposal-apply.service.ts:173-176: a chapter's rewrites land as one revision whose undo is stored under the first, so the whole revert restores the draft
  // through that one change and leaves the carried rewrite, which holds no undo, to it
  @Test func shouldRestoreADraftsRewrittenRevisionThroughItsFirstRewrite() async throws {
    let book = try await StagingWorld.workspace()
    let wrist = StagingText.rewrite(StagingText.wrist, StagingText.wristRewrite)
    let id = try await book.stage(wrist, StagingText.rewrite(StagingText.fear, StagingText.fearRewrite), kind: .chat).proposal.id
    let before = try await book.states(["draft:3"])
    _ = try await book.applied(id)
    #expect(try await book.change(id, 1).undo == nil)
    #expect(await book.undoRefusal(id, 1) == .notToggleable(index: 1))

    #expect(try await book.revertCard(id).reverted == [0])

    #expect(try await book.states(["draft:3"]) == before)
    #expect(try await book.draftContent(3)?.body == StagingText.body)
    #expect(try await book.statuses(id) == [.reverted, .applied])
  }

  // DraftHandlers.settleWorkingCopies before the guard: unsaved edits over the rewritten draft are committed, so the guard sees them and refuses
  @Test func shouldSettleTheWorkingCopyBeforeTheGuardOfADraftRevert() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(StagingText.rewrite(StagingText.fear, StagingText.fearRewrite), kind: .chat).proposal.id
    _ = try await book.applied(id)
    let head = try #require(try await book.head(3))
    let novel = book.novel
    var content = try #require(try await book.draftContent(3))
    content.body += "\n\nMine."
    try await book.run { [content] transaction in try DraftWorkingCopy(novel: novel, chapter: 3, base: head, content: content).save(in: transaction.database) }

    #expect(await book.revertRefusal(id)?.code == "RFN_006")
    #expect(try await book.workingCopy(3) != nil)
    #expect(try await book.draftContent(3)?.body.contains(StagingText.fearRewrite) == true)
  }
}

enum RevertTestError: Error {
  case unexpected
}
