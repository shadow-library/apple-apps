import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private typealias World = ApplyWorld
private typealias Text = StagingText

private func statuses(_ outcomes: [ProposalChangeOutcome]) -> [Int: ProposalChangeStatus] {
  Dictionary(uniqueKeysWithValues: outcomes.map { ($0.index, $0.status) })
}

/// The staged card with operation `index` replaced by `stored`, saved as a new pending proposal, as a card staged by an earlier version reads here.
private func restaged(_ card: ProposalCard, replacing index: Int, with stored: String, in book: ChapterBook) async throws -> UUID {
  var members = try #require(card.json.objectValue)
  var ops = try #require(members[ProposalCardMember.changeSet.rawValue]?.arrayValue)
  ops[index] = try #require(try OrderedJSON(parsing: stored).storable)
  members[ProposalCardMember.changeSet.rawValue] = .array(ops)
  let rewritten = try #require(ProposalCard(json: .object(members)))
  let id = UUID()
  try await book.run { transaction in _ = try ProposalRecord(id: id, card: rewritten).create(in: &transaction) }
  return id
}

// apps/novel-forge-server/src/modules/refinement/proposal-apply.service.ts:109-247
@Suite("Proposal apply", TestTimeLimit.standard)
struct ProposalApplyTests {
  @Test func shouldApplyEveryContentOpOfAWholeCardAndRecordEachChangeWithItsOwnUndo() async throws {
    let book = try await StagingWorld.workspace()
    let staged = try await book.stage(World.maraMotive, World.kael, World.premise)
    let id = staged.proposal.id
    let outcomes = try await book.applied(id)
    #expect(statuses(outcomes) == [0: .applied, 1: .applied, 2: .applied])
    #expect(outcomes.allSatisfy { $0.failure == nil && $0.source == nil })

    #expect(try await book.entity("mara")?.motivation == "She wants the lamp.")
    #expect(try await book.entity("kael")?.name == "Kael")
    #expect(try await book.premise() == "A fencer keeps a lamp.")
    let proposal = try await book.proposal(id)
    #expect(proposal.decision == .known(.applied))
    #expect(proposal.application?.selected == [0, 1, 2])
    #expect(proposal.application?.automatic == false)
    let refs = ["entity:mara", "entity:kael", "premise"]
    #expect(proposal.application?.postState == ArtifactStates(try await book.states(refs)))

    let mara = try await book.change(id, 0)
    #expect(mara.status == .known(.applied))
    let undo = try #require(mara.undo)
    #expect(undo.inverse["op"]?.stringValue == "entity.upsert")
    #expect(undo.priorState["entity:mara"] == staged.proposal.card.baseline["entity:mara"])
    #expect(undo.postState["entity:mara"] == (try await book.states(["entity:mara"]))[JSString("entity:mara")])
    #expect(try await book.change(id, 1).undo?.priorState["entity:kael"] == .missing)
  }

  // proposal-apply.service.ts:232-238: an unselected index has no change record and reads as declined
  @Test func shouldRecordOnlyTheSelectedIndexesAndLeaveTheRestDeclined() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(World.maraMotive, World.kael).proposal.id
    let outcomes = try await book.applied(id, .indexes([1, 1]))
    #expect(outcomes.map(\.index) == [1])
    let changes = try await book.changes(id)
    #expect(changes.first == .declined)
    #expect(try await book.change(id, 1).status == .known(.applied))
    #expect(try await book.entity("mara")?.motivation == nil)
    #expect(try await book.entity("kael") != nil)
    #expect(try await book.proposal(id).application?.selected == [1])
  }

  // proposal-apply.service.ts:241-247 (RFN_011)
  @Test func shouldRefuseASelectionOutsideTheCardAndWriteNothing() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(World.kael).proposal.id
    for selection in [ApplySelection.indexes([]), .indexes([1]), .indexes([-1])] {
      #expect(await book.applyError(id, selection) == .apply(.invalidSelection))
    }
    #expect(try await book.decision(id) == .known(.pending))
    #expect(try await book.entity("kael") == nil)
  }

  // proposal-apply.service.ts:118-119 (RFN_001, RFN_002)
  @Test func shouldRefuseAProposalThatIsNotPendingOrNotOfThisNovel() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    let discarded = try await book.stage(World.kael).proposal.id
    try await book.run { try ProposalDiscard.discard(discarded, novel: novel, in: &$0) }
    #expect(await book.applyError(discarded) == .notPending(.known(.discarded)))

    let applied = try await book.stage(World.premise, session: nil).proposal.id
    _ = try await book.applied(applied)
    #expect(await book.applyError(applied) == .notPending(.known(.applied)))

    let missing = UUID()
    #expect(await book.applyError(missing) == .notFound(missing))
    let other = ProposalApplyContext(novel: SchemaFixture.otherNovel, now: book.clock.now)
    #expect(await book.applyError(applied, context: other) == .notFound(applied))
  }

  // proposal-apply.service.ts:141-160, :302-321: a record changed since staging stops the whole card and records nothing
  @Test func shouldReportAConflictForTheWholeCardAndRecordNothing() async throws {
    let book = try await StagingWorld.workspace()
    let stale = try await book.stage(World.maraMotive, World.kael, session: nil).proposal.id
    let edit = try await book.stage(#"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","notes":"Left-handed."}"#).proposal.id
    _ = try await book.applied(edit)

    guard case .conflicted(let mismatches) = try await book.apply(stale) else {
      Issue.record("a card staged over an earlier mara applied")
      return
    }
    #expect(mismatches.map(\.ref) == ["entity:mara"])
    #expect(mismatches.first?.indexes == [0])
    #expect(try await book.decision(stale) == .known(.pending))
    #expect(try await book.changes(stale) == [.notApplied, .notApplied])
    #expect(try await book.entity("kael") == nil)
    #expect(try await book.entity("mara")?.motivation == nil)
  }

  // RULES F03: a stored op that no longer validates is a failed change, never an error that blocks the card
  @Test func shouldRecordAStoredOpThatNoLongerValidatesAsFailedAndApplyTheRest() async throws {
    let book = try await StagingWorld.workspace()
    let card = try await book.stage(World.maraMotive, World.kael, session: nil).proposal.card
    let id = try await restaged(card, replacing: 1, with: #"{"op":"entity.upsert","entityKey":"kael"}"#, in: book)
    let outcomes = try await book.applied(id)
    #expect(statuses(outcomes) == [0: .applied, 1: .failed])
    let failure = try #require(outcomes.last?.failure)
    #expect(failure.code == "RFN_004")
    #expect(failure.message.contains("changeSet[1]"))
    let stored = try await book.change(id, 1)
    #expect(stored.status == .known(.failed))
    #expect(stored.result?.error == failure.message)
    #expect(stored.result?.result == ["code": "RFN_004"])
    #expect(stored.undo == nil)
    #expect(try await book.entity("kael") == nil)
    #expect(try await book.entity("mara")?.motivation == "She wants the lamp.")
  }

  // proposal-apply.service.ts:106 (DECIDED for F16): any handler error rolls the whole apply back, and the error names the index to leave out
  @Test func shouldAbortTheWholeApplyOnARefusalMidCardAndNameItsIndex() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(World.maraMotive, World.missingVolume, World.kael).proposal.id
    let refusal = await book.applyError(id)
    #expect(refusal == .changeRefused(indexes: [1], .domain(.volumeNotFound("volume_9"))))
    #expect(refusal?.code == "VOL_001")
    #expect(try await book.decision(id) == .known(.pending))
    #expect(try await book.changes(id) == [.notApplied, .notApplied, .notApplied])
    #expect(try await book.entity("mara")?.motivation == nil)
    #expect(try await book.entity("kael") == nil)
    #expect(statuses(try await book.applied(id, .indexes([0, 2]))) == [0: .applied, 2: .applied])
    #expect(try await book.changes(id)[1] == .declined)
  }

  // RULES F11b: a handler that throws after writing abandons the whole apply
  @Test func shouldAbortTheWholeApplyOnAPartialWrite() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    let id = try await book.stage(World.maraMotive, World.kael).proposal.id
    let context = book.context()
    do {
      _ = try await book.store.write { transaction in
        try ProposalApply.apply(proposal: id, selection: .whole, context: context, in: &transaction) { call, context, transaction throws(ApplyError) in
          guard call.refs == ["entity:kael"] else { return try ApplyFrame.perform(call, context: context, in: &transaction) }
          return try ApplyFrame.perform(call, context: context, in: &transaction) { _, _, transaction throws(ApplyError) in
            do throws(StoreError) {
              _ = try EntityRecord(novel: novel, entity: "kael", type: .known(.character), name: "Kael").create(in: &transaction)
            } catch {
              throw .store(error)
            }
            throw .domain(.entityExists("kael"))
          }
        }
      }
      Issue.record("an apply that half wrote a change committed")
    } catch {
      guard case .aborted(let cause) = error else { throw error }
      #expect(cause as? ProposalApplyError == .apply(.partialWrite(ref: "entity:kael")))
    }
    #expect(try await book.decision(id) == .known(.pending))
    #expect(try await book.changes(id) == [.notApplied, .notApplied])
    #expect(try await book.entity("mara")?.motivation == nil)
    #expect(try await book.entity("kael") == nil)
  }

  // apply-rules.ts:46-51: the plans are judged as the whole change set leaves them, and a broken rule rolls everything back
  @Test func shouldAbortTheWholeApplyWhenThePlansBreakARuleOnlyTogether() async throws {
    let book = try await StagingWorld.workspace()
    let plan = #"{"op":"brief.update","chapter":6,"body":"Mara learns the tide.","knowledgeContract":{"pov":["mara"],"learns":[{"entityKey":"mara","factKey":"tide"}]}}"#
    let id = try await book.stage(plan, #"{"op":"fact.upsert","factKey":"tide","revealChapter":9}"#, World.kael).proposal.id
    guard case .domain(let refusal)? = await book.applyError(id) else {
      Issue.record("a plan revealing a fact before its date was applied")
      return
    }
    #expect(refusal.code == DomainError.planRevealsLocked(chapter: 6, violations: "").code)
    #expect(try await book.decision(id) == .known(.pending))
    #expect(try await book.livePlan(6) == nil)
    #expect(try await book.entity("kael") == nil)
  }

  // RULES F14: this device's working copy is committed before the baseline check, so the inverse restores the author's own text
  @Test func shouldSettleTheWorkingCopyBeforeTheBaselineCheckAndCaptureItInTheInverse() async throws {
    let book = try await StagingWorld.workspace()
    let edited = "Dawn.\n\n\(Text.body)"
    try await book.save(3, edited, summary: "It turns.", base: try await book.head(3))
    let id = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#).proposal.id
    #expect(statuses(try await book.applied(id)) == [0: .applied])
    #expect(try await book.workingCopy(3) == nil)
    let draft = try #require(try await book.draftContent(3))
    #expect(draft.title == "The Bout" && draft.body == edited)
    #expect(try await book.change(id, 0).undo?.inverse["body"]?.stringValue == edited)
  }

  // proposal-apply.service.ts:172-181: a chapter's selected rewrites land as one revision, its undo and states under the first index only
  @Test func shouldLandAChaptersRewritesAsOneRevisionWithTheUndoOnTheFirstIndex() async throws {
    let book = try await StagingWorld.workspace()
    let revisions = try await book.revisionCount(3)
    let id = try await book.stage(Text.rewrite(Text.wrist, Text.wristRewrite), Text.rewrite(Text.fear, Text.fearRewrite)).proposal.id
    #expect(statuses(try await book.applied(id)) == [0: .applied, 1: .applied])
    #expect(try await book.revisionCount(3) == revisions + 1)
    let body = try #require(try await book.draftContent(3)?.body)
    #expect(body.contains(Text.wristRewrite) && body.contains(Text.fearRewrite))
    let first = try await book.change(id, 0)
    #expect(first.undo?.priorState["draft:3"] != nil && first.undo?.postState["draft:3"] != nil)
    let carried = try await book.change(id, 1)
    #expect(carried.status == .known(.applied) && carried.undo == nil && carried.result == nil)
  }

  // RFN_021: a rewrite whose passage is gone refuses the apply, naming every rewrite of its chapter, and the card stays pending to apply the others
  @Test func shouldRefuseTheApplyNamingEveryRewriteOfAChapterWhosePassageIsGone() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(Text.rewrite(Text.wrist, Text.wristRewrite), World.kael, Text.rewrite(Text.fear, Text.fearRewrite)).proposal.id
    try await book.reviseElsewhere(3, Text.body.replacingOccurrences(of: Text.fear, with: "He was not afraid."))
    let head = try await book.head(3)
    guard case .changeRefused(let indexes, let cause)? = await book.applyError(id) else {
      Issue.record("a rewrite of a passage that is gone applied")
      return
    }
    #expect(indexes == [0, 2])
    #expect(cause.code == "RFN_021")
    #expect(cause.errorDescription?.contains("uncheck it to apply the others") == true)
    #expect(try await book.decision(id) == .known(.pending))
    #expect(try await book.head(3) == head)
    #expect(try await book.entity("kael") == nil)
    #expect(statuses(try await book.applied(id, .indexes([1]))) == [1: .applied])
  }

  // apply/unrestricted-raise.ts:18-34 (AI_024): a raise is refused unless the caller found unrestricted writing available
  @Test func shouldRaiseAPlanToUnrestrictedOnlyWhenTheCallerHasItAvailable() async throws {
    #expect(!UnrestrictedWriting.isAvailable)
    let book = try await StagingWorld.workspace()
    let raise = #"{"op":"brief.update","chapter":4,"body":"Mara leaves.","contentMode":"unrestricted"}"#
    let refused = try await book.stage(raise, session: nil).proposal.id
    #expect(await book.applyError(refused) == .changeRefused(indexes: [0], .refused(.unrestrictedUnavailable)))
    #expect(try await book.decision(refused) == .known(.pending))
    #expect(try await book.livePlan(4) == nil)

    let allowed = try await book.stage(raise, session: nil).proposal.id
    #expect(statuses(try await book.applied(allowed, context: book.context(unrestricted: true))) == [0: .applied])
    #expect(try await book.livePlan(4)?.contentMode == .known(.unrestricted))
  }

  // proposal-apply-plan-card.spec.ts:54 (PLN_008): a plan pass card for a chapter the story moved past is refused and stays pending
  @Test func shouldRefuseAPlanPassCardForAChapterTheStoryHasMovedPast() async throws {
    let book = try await StagingWorld.workspace()
    let stale = try await book.stage(#"{"op":"brief.update","chapter":3,"body":"Mara tests the lamp."}"#, session: nil, kind: .chapterPlan).proposal.id
    #expect(await book.applyError(stale) == .planCardStale(chapter: 3, next: 4))
    #expect(try await book.decision(stale) == .known(.pending))
    #expect(try await book.livePlan(3) == nil)
    let current = try await book.stage(#"{"op":"brief.update","chapter":4,"body":"Mara tests the lamp."}"#, session: nil, kind: .chapterPlan).proposal.id
    #expect(statuses(try await book.applied(current)) == [0: .applied])
    let chat = try await book.stage(#"{"op":"brief.update","chapter":3,"body":"Mara tests the lamp."}"#, session: nil, kind: .chat).proposal.id
    #expect(statuses(try await book.applied(chat)) == [0: .applied])
  }

  // proposal-apply.service.ts:131-133, :162; proposal-apply-volumes.spec.ts:250, :258-270
  @Test func shouldRefuseAnAutomaticApplyCarryingAnActionOrAnAlwaysCardOp() async throws {
    let book = try await StagingWorld.workspace()
    let automatic = book.context(automatic: true)
    let action = try await book.stage(World.kael, World.advance("volume_1"), session: nil).proposal.id
    #expect(await book.applyError(action, .indexes([0, 1]), context: automatic) == .automaticAction)
    let removal = try await book.stage(World.missingVolume, session: nil).proposal.id
    #expect(await book.applyError(removal, context: automatic) == .automaticAlwaysCard(.volumeRemove))
    let plan = try await book.stage(#"{"op":"brief.update","chapter":4,"body":"Mara leaves."}"#, session: nil).proposal.id
    #expect(await book.applyError(plan, context: automatic) == .automaticAlwaysCard(.briefUpdate))
    let sourced = try await book.stage(World.kael, World.premise, session: nil).proposal.id
    #expect(await book.applyError(sourced, context: book.context(automatic: true, sources: [.idea])) == .sourcesMismatch(expected: 2, found: 1))
    for id in [action, removal, plan, sourced] { #expect(try await book.decision(id) == .known(.pending)) }
  }

  // proposal-apply-op-undo.spec.ts:86-98: each applied op's source is kept on the first applier's object
  @Test func shouldKeepEachSourceOfAnAutomaticApply() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(World.maraMotive, World.kael).proposal.id
    let outcomes = try await book.applied(id, context: book.context(automatic: true, sources: [.quoted, .idea]))
    #expect(outcomes.map(\.source) == [.quoted, .idea])
    let application = try #require(try await book.proposal(id).application)
    #expect(application.automatic)
    #expect(application.sources == [.known(.quoted), .known(.idea)])
  }

  // proposal-apply.service.ts:134-135 and proposal-apply-volumes.spec.ts:244: a blanket apply refuses the one-way doors before writing anything
  @Test func shouldRefuseEveryOneWayDoorOnAWholeCardApplyAndWriteNothing() async throws {
    let book = try await StagingWorld.workspace()
    let doors: [(String, OpType, String)] = [
      (World.finalize3, .actionFinalize, "RFN_009"), (World.approve3, .actionApproveDraft, "DRF_009"), (World.advance("volume_1"), .actionAdvanceVolume, "VOL_004"),
      (#"{"op":"action.generate_chapter","chapter":4}"#, .actionGenerateChapter, "DRF_014"),
      (#"{"op":"action.apply_continuity","chapter":2}"#, .actionApplyContinuity, "CNT_002"),
    ]
    for (op, type, code) in doors {
      let id = try await book.stage(World.kael, op, session: nil).proposal.id
      let refusal = await book.applyError(id)
      #expect(refusal == .oneWayDoor(type))
      #expect(refusal?.code == code)
      #expect(try await book.decision(id) == .known(.pending))
    }
    #expect(try await book.entity("kael") == nil)
  }

  // proposal-apply.service.ts:137-139 (RFN_008): an action this version cannot run refuses the apply; phase 7 brings the job actions
  @Test func shouldRefuseAnActionThatIsNotYetAvailableBeforeWritingAnything() async throws {
    let book = try await StagingWorld.workspace()
    let id = try await book.stage(World.kael, #"{"op":"action.validate","scope":"novel"}"#, session: nil).proposal.id
    #expect(await book.applyError(id, .indexes([0, 1])) == .apply(.notYetAvailable(.actionValidate)))
    #expect(try await book.decision(id) == .known(.pending))
    #expect(try await book.entity("kael") == nil)
    #expect(statuses(try await book.applied(id, .indexes([0]))) == [0: .applied])
  }
}
