import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private typealias Text = StagingText
private typealias World = StagingWorld

private func storedOp(_ card: ProposalCard, _ index: Int) throws -> OrderedJSONObject {
  try #require(OrderedJSON(card.changeSet[index].stored).objectValue)
}

private func anchor(_ card: ProposalCard, _ index: Int) throws -> OrderedJSONObject {
  try #require(try storedOp(card, index)["anchor"]?.objectValue)
}

private func number(_ value: OrderedJSON?) -> Int? {
  value?.numberValue.flatMap { Int(exactly: $0) }
}

// apps/novel-forge-server/src/modules/refinement/proposal.service.ts:138-182
@Suite("Proposal staging", TestTimeLimit.standard)
struct ProposalStagingTests {
  @Test func shouldCaptureABaselineEqualToTheArtifactStatesOfTheCurrentRecords() async throws {
    let book = try await World.workspace()
    let staged = try await book.stage(
      #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She wants the lamp."}"#,
      #"{"op":"entity.upsert","entityKey":"kael","type":"character","name":"Kael"}"#, #"{"op":"fact.upsert","factKey":"heir","body":"The heir lives."}"#,
      #"{"op":"draft.update","chapter":3,"title":"The Bout"}"#, #"{"op":"premise.update","premise":"A fencer."}"#)
    let refs = ["entity:mara", "entity:kael", "fact:heir", "draft:3", "premise"]
    let current = try await book.states(refs)
    #expect(staged.proposal.card.baseline == ArtifactStates(current))
    #expect(Set(staged.proposal.card.baseline.refs) == Set(refs))
    #expect(staged.proposal.card.baseline["entity:kael"] == .missing)
    #expect(current[JSString("entity:mara")]?.contentHash != nil)
    #expect(try await book.proposal(staged.proposal.id) == staged.proposal)
    #expect(staged.proposal.decision == .known(.pending))
  }

  @Test func shouldTakeTheCallersBaselineForTheChangeSetsRefsOnly() async throws {
    let book = try await World.workspace()
    let earlier = ArtifactState(exists: true, revision: nil, contentHash: "read-before")
    var input = World.input(try World.changeSet(#"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara"}"#), novel: book.novel)
    input.baseline = ArtifactStates([JSString("entity:mara"): earlier, JSString("fact:heir"): .missing])
    let staged = try await book.stage(input)
    #expect(staged.proposal.card.baseline == ArtifactStates([JSString("entity:mara"): earlier]))
    input.baseline = ArtifactStates()
    #expect(try await book.stage(input).proposal.card.baseline == ArtifactStates([JSString("entity:mara"): .missing]))
  }

  // RULES F11a: an unreadable record is stored as unreadable, so the apply-time baseline check conflicts
  @Test func shouldStoreARecordThisDeviceCannotReadAsUnreadableSoItNeverMatches() async throws {
    let book = try await World.workspace()
    let novel = book.novel
    let ghost = NovelForgeKey.entityKey(novel: novel, entity: "ghost")
    try await book.run { transaction in _ = try transaction.set(ghost.ref, ["natural_key": ghost.stored, "removed": .bool(false)]) }
    let staged = try await book.stage(#"{"op":"entity.upsert","entityKey":"ghost","type":"character","name":"Ghost"}"#)
    let stored = try #require(staged.proposal.card.baseline["entity:ghost"])
    #expect(stored.isUnreadable)
    #expect(!stored.matches(try #require(try await book.states(["entity:ghost"])[JSString("entity:ghost")])))
    #expect(try await book.proposal(staged.proposal.id).card.baseline["entity:ghost"]?.isUnreadable == true)
  }

  // RULES F14 (F15): the working copy is settled before a draft's baseline is captured
  @Test func shouldReadTheDraftThroughThisDevicesWorkingCopyWithoutCommittingIt() async throws {
    let book = try await World.workspace()
    let novel = book.novel
    let head = try #require(try await book.head(3))
    let edited = "Dawn.\n\n\(Text.body)"
    try await book.save(3, edited, summary: "It turns.", base: head)
    let revisions = try await book.revisionCount(3)
    let staged = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#)
    #expect(try await book.revisionCount(3) == revisions)
    #expect(try await book.head(3) == head)
    #expect(try await book.workingCopy(3)?.content.body == edited)
    try await book.save(3, "Dusk.\n\n\(edited)", summary: "It turns.", base: head)
    try await book.run { try DraftHandlers.settleWorkingCopies(chapters: [3], novel: novel, in: &$0) }
    #expect(try await book.draftContent(3)?.body == "Dusk.\n\n\(edited)")
    let settled = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#, session: nil).proposal.card.baseline
    #expect(settled == ArtifactStates(try await book.states(["draft:3"])))
    #expect(staged.proposal.card.baseline != settled)
  }

  // F16's settle commits exactly the copy staging read, so the baseline matches at apply
  @Test func shouldCaptureTheStateTheApplysSettleWillFind() async throws {
    let book = try await World.workspace()
    let novel = book.novel
    try await book.save(3, "Dawn.\n\n\(Text.body)", summary: "It turns.", base: try await book.head(3))
    let baseline = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#).proposal.card.baseline
    let settled = try await book.run { transaction in
      try DraftHandlers.settleWorkingCopies(chapters: [3], novel: novel, in: &transaction)
      return try ArtifactStateLoader.states(refs: ["draft:3"], novel: novel, in: transaction)
    }
    let stored = try #require(baseline["draft:3"])
    #expect(stored.matches(try #require(settled[JSString("draft:3")])))
  }

  // A final chapter's copy is left alone by the settle, so it is never read through
  @Test func shouldNotReadAFinalChaptersWorkingCopyThrough() async throws {
    let book = try await World.workspace()
    let novel = book.novel
    let head = try #require(try await book.head(2))
    try await book.run { transaction in
      let copy = DraftWorkingCopy(
        novel: novel, chapter: 2, base: head, content: DraftContent(body: "Unsaved.", summary: "It turns.", source: .known(.handEdited), generator: .known(.human)))
      try copy.save(in: transaction.database)
    }
    let baseline = try await book.stage(#"{"op":"draft.update","chapter":2,"title":"The Bout"}"#).proposal.card.baseline
    #expect(baseline == ArtifactStates(try await book.states(["draft:2"])))
    #expect(try await book.workingCopy(2) != nil)
  }

  // proposal-warnings.ts:38 reads the stored prose; here that is the prose the author sees, the working copy included
  @Test func shouldReviewNegationEchoesAgainstTheWorkingCopy() async throws {
    let book = try await World.workspace()
    let unsaved = "Mara carries a dagger to the tower."
    try await book.save(3, unsaved, summary: "It turns.", base: try await book.head(3))
    let op = #"{"op":"draft.update","chapter":3,"body":"Mara carries no dagger to the tower."}"#
    let baseline: BaselineTexts = [JSString("draft:3"): ["title": nil, "body": unsaved, "summary": "It turns."]]
    let expected = try #require(ProposalWarnings.negationEchoes(try World.changeSet(op).ops, baselines: baseline))
    #expect(!expected.isEmpty)
    #expect(try await book.stage(op, warnings: nil).proposal.card.warnings == expected)
  }

  // A copy over a moved head is kept aside by the settle, never read through
  @Test func shouldIgnoreAWorkingCopyOverAMovedHead() async throws {
    let book = try await World.workspace()
    let novel = book.novel
    let old = try #require(try await book.head(3))
    try await book.save(3, "Mine.\n\n\(Text.body)", summary: "It turns.", base: old)
    try await book.run { transaction in
      let content = DraftContent(body: "Theirs.\n\n\(Text.body)", summary: "It turns.", source: .known(.handEdited), generator: .known(.human))
      _ = try DraftRecord.revise(try DraftRecord.ref(novel: novel, chapter: 3), content, in: &transaction)
    }
    let baseline = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Bout"}"#).proposal.card.baseline
    #expect(baseline == ArtifactStates(try await book.states(["draft:3"])))
  }

  // passage-rewrite.spec.ts:399
  @Test func shouldStageEachRewriteWithItsAnchorAndTheDraftsBaseline() async throws {
    let book = try await World.workspace()
    let staged = try await book.stage(Text.rewrite(Text.wrist, Text.wristRewrite), Text.rewrite(Text.fear, Text.fearRewrite))
    let card = staged.proposal.card
    let identity = try #require(try await book.identity(3))
    let generation = try #require(try await book.history(3)?.headEntry?.generation)
    for (index, paragraph) in [(0, 2), (1, 4)] {
      let stamped = try anchor(card, index)
      #expect(number(stamped["paragraph"]) == paragraph)
      #expect(stamped["draftId"]?.stringValue == identity)
      #expect(number(stamped["revision"]) == Int(generation))
      #expect(number(stamped["saveSeq"]) == 0)
    }
    #expect(number(try anchor(card, 1)["start"]) == Text.body.jsIndexOf(Text.fear))
    #expect(card.baseline.refs == ["draft:3"])
  }

  // passage-rewrite.spec.ts:248, through the settled working copy
  @Test func shouldAnchorAfreshAPassageThatMovedInTheWorkingCopy() async throws {
    let book = try await World.workspace()
    let moved = "Dawn.\n\n\(Text.body)"
    try await book.save(3, moved, summary: "It turns.", base: try await book.head(3))
    let revisions = try await book.revisionCount(3)
    let card = try await book.stage(Text.rewrite(Text.fear, Text.fearRewrite)).proposal.card
    let stamped = try anchor(card, 0)
    #expect(number(stamped["start"]) == moved.jsIndexOf(Text.fear))
    #expect(number(stamped["paragraph"]) == 5)
    #expect(try await book.revisionCount(3) == revisions)
    #expect(try await book.workingCopy(3)?.content.body == moved)
  }

  // passage-rewrite.spec.ts:266-274, :179
  @Test func shouldRefuseARewriteItCannotPlaceAndStageNothing() async throws {
    let book = try await World.workspace()
    let cases: [(String, ProposalStagingError)] = [
      (Text.rewrite("Again", "Once more"), .rewriteNotPlaced(chapter: 3, reason: .ambiguous)),
      (Text.rewrite("not in the chapter", "x"), .rewriteNotPlaced(chapter: 3, reason: .notFound)),
      (Text.rewrite(Text.fear, Text.fear), .rewriteNotPlaced(chapter: 3, reason: .unchanged)),
      (Text.rewrite("tide", "sea", chapter: 2), .rewriteNotPlaced(chapter: 2, reason: .locked)),
      (Text.rewrite("tide", "sea", chapter: 4), .rewriteNotPlaced(chapter: 4, reason: .noDraft)),
      (Text.rewrite(String(repeating: "x", count: 6001), "y"), .rewriteNotPlaced(chapter: 3, reason: .tooLong)),
    ]
    for (op, refusal) in cases {
      #expect(await book.refusal(World.input(try World.changeSet(op), novel: book.novel)) == refusal)
    }
    let whole = try World.changeSet(Text.rewrite(Text.wrist, Text.wristRewrite), #"{"op":"draft.update","chapter":3,"body":"New."}"#)
    #expect(await book.refusal(World.input(whole, novel: book.novel)) == .rewriteNotPlaced(chapter: 3, reason: .wholeChapter))
    #expect(try await book.proposalCount() == 0)
  }

  @Test func shouldRefuseARewriteOfAnIsolatedDraft() async throws {
    let book = try await World.book()
    let novel = book.novel
    _ = try await book.run { try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: Text.body, isolated: true), base: nil, in: &$0) }
    let input = World.input(try World.changeSet(Text.rewrite(Text.wrist, Text.wristRewrite, chapter: 1)), novel: novel)
    #expect(await book.refusal(input) == .rewriteNotPlaced(chapter: 1, reason: .isolated))
  }

  @Test func shouldRefuseANovelThatDoesNotExistAndAPluginCardOutsideItsAllowlist() async throws {
    let book = try await World.book()
    let other = SchemaFixture.otherNovel
    #expect(await book.refusal(World.input(try World.changeSet(#"{"op":"premise.update","premise":"x"}"#), novel: other)) == .domain(.novelNotFound(other)))
    let plugin = World.input(try World.changeSet(#"{"op":"premise.update","premise":"x"}"#), novel: book.novel, session: nil, kind: .plugin)
    #expect(await book.refusal(plugin)?.code == "RFN_004")
  }

  // apps/novel-forge-server/tests/refinement/proposal-started-empty.spec.ts:21; idea-id.ts:37
  @Test func shouldDropTheStartedEmptyMarkAndStampEveryContentOpsIdeaId() async throws {
    let book = try await World.book()
    let plan = #"{"op":"brief.update","chapter":4,"body":"x","startedEmpty":true,"ideaId":"forged"}"#
    let card = try await book.stage(plan, #"{"op":"action.audit_bible","ideaId":"forged"}"#).proposal.card
    let first = try storedOp(card, 0)
    #expect(first["startedEmpty"] == nil)
    let ideas = try #require(IdeaIdentity.shared)
    let op = try #require(card.ops[0])
    #expect(first["ideaId"]?.stringValue == ideas.ideaId(of: op))
    #expect(try storedOp(card, 1)["ideaId"] == nil)
    let kept = try await book.stage(plan, kind: .chapterPlan).proposal.card
    #expect(try storedOp(kept, 0)["startedEmpty"] == .bool(true))
  }

  // proposal.service.ts:106 with keepSupplied false; hub-action.registrar.ts:72
  @Test func shouldBindAnApprovalToTheDraftAsItStandsAndLeaveAChapterWithoutOneUnstamped() async throws {
    let book = try await World.workspace()
    let card = try await book.stage(
      #"{"op":"action.approve_draft","chapter":3,"revision":99,"saveSeq":5,"draftId":"forged"}"#,
      #"{"op":"action.approve_draft","chapter":4,"revision":1,"saveSeq":0,"draftId":"4"}"#
    ).proposal.card
    let stamped = try storedOp(card, 0)
    let identity = try #require(try await book.identity(3))
    #expect(stamped["draftId"]?.stringValue == "\(identity)/\(try #require(try await book.head(3)))")
    #expect(number(stamped["revision"]) == Int(try #require(try await book.history(3)?.headEntry?.generation)))
    #expect(number(stamped["saveSeq"]) == 0)
    let bare = try storedOp(card, 1)
    #expect(bare["draftId"] == nil && bare["revision"] == nil && bare["saveSeq"] == nil)
    #expect(card.baseline.refs.isEmpty)
  }

  // An approval binds a real revision: its chapter's working copy is committed first, as approving from the editor does
  @Test func shouldCommitTheWorkingCopyOfAChapterAnApprovalBindsTo() async throws {
    let book = try await World.workspace()
    try await book.save(3, "Dawn.\n\n\(Text.body)", summary: "It turns.", base: try await book.head(3))
    let revisions = try await book.revisionCount(3)
    let card = try await book.stage(#"{"op":"action.approve_draft","chapter":3}"#).proposal.card
    #expect(try await book.revisionCount(3) == revisions + 1)
    #expect(try await book.workingCopy(3) == nil)
    let head = try #require(try await book.head(3))
    #expect(try storedOp(card, 0)["draftId"]?.stringValue == "\(try #require(try await book.identity(3)))/\(head)")
  }

  // An approval over this device's copy of an earlier head would bind another device's text while the author's copy goes aside
  @Test func shouldRefuseAnApprovalOfAChapterWhoseWorkingCopyRestsOnAnEarlierHead() async throws {
    let book = try await World.workspace()
    let novel = book.novel
    try await book.save(3, "Mine.\n\n\(Text.body)", summary: "It turns.", base: try await book.head(3))
    try await book.run { transaction in
      let content = DraftContent(body: "Theirs.\n\n\(Text.body)", summary: "It turns.", source: .known(.handEdited), generator: .known(.human))
      _ = try DraftRecord.revise(try DraftRecord.ref(novel: novel, chapter: 3), content, in: &transaction)
    }
    let revisions = try await book.revisionCount(3)
    let input = World.input(try World.changeSet(#"{"op":"action.approve_draft","chapter":3}"#), novel: novel)
    #expect(await book.refusal(input) == .approvalOverMovedDraft(chapter: 3))
    #expect(try await book.workingCopy(3)?.content.body.hasPrefix("Mine.") == true)
    #expect(try await book.revisionCount(3) == revisions)
    #expect(try await book.proposalCount() == 0)
  }

  @Test func shouldLeaveAnApprovalOfADraftThisDeviceCannotReadUnstampedAndStageIt() async throws {
    let book = try await World.workspace()
    let novel = book.novel
    try await book.run { transaction in _ = try transaction.revise(try DraftRecord.ref(novel: novel, chapter: 3), body: .object([:])) }
    let card = try await book.stage(#"{"op":"action.approve_draft","chapter":3,"revision":1,"saveSeq":0,"draftId":"3"}"#).proposal.card
    let bare = try storedOp(card, 0)
    #expect(bare["draftId"] == nil && bare["revision"] == nil && bare["saveSeq"] == nil)
  }

  // apps/novel-forge-server/tests/refinement/proposal-service-warnings.spec.ts:18-36
  @Test func shouldCarryTheRevealClearWarningOnlyWhenTheFactIsCurrentlyDated() async throws {
    let book = try await World.book()
    let novel = book.novel
    try await book.run { try PlanWorldWrites.secret(novel: novel, "loose", in: &$0) }
    let dated = try await book.stage(#"{"op":"fact.upsert","factKey":"tide","revealChapter":null}"#).proposal.card
    let warning =
      "fact:tide is scheduled to reveal at chapter 5; this clears that date, so only an unlock condition can let a plan reveal it — check that's intended."
    #expect(dated.warnings == [warning])
    #expect(dated.diagnostics == [ProposalDiagnostic(kind: .known(.other), message: warning)])
    let undated = try await book.stage(#"{"op":"fact.upsert","factKey":"loose","revealChapter":null}"#).proposal.card
    #expect(undated.warnings.isEmpty && undated.diagnostics.isEmpty)
    let omitted = try await book.stage(#"{"op":"fact.upsert","factKey":"tide","body":"x"}"#).proposal.card
    #expect(omitted.warnings.isEmpty)
  }

  // proposal.service.ts:147-153: caller warnings replace only the negation-echo review; the isolated-source warning comes last
  @Test func shouldReviewNegationEchoesUnlessTheCallerSuppliedWarnings() async throws {
    let book = try await World.book()
    let novel = book.novel
    try await book.run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(motivation: "She carries a dagger to the tower."), in: &$0) }
    let op = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She carries no dagger to the tower."}"#
    let ops = try World.changeSet(op).ops
    let baseline: BaselineTexts = [JSString("entity:mara"): ["status": nil, "motivation": "She carries a dagger to the tower.", "notes": nil, "body": nil]]
    let expected = try #require(ProposalWarnings.negationEchoes(ops, baselines: baseline))
    #expect(!expected.isEmpty)
    #expect(try await book.stage(op, warnings: nil).proposal.card.warnings == expected)
    #expect(try await book.stage(op, warnings: ["From the turn."]).proposal.card.warnings == ["From the turn."])
    var input = World.input(try World.changeSet(#"{"op":"fact.upsert","factKey":"tide","revealChapter":null}"#), novel: novel, warnings: ["From the turn."])
    input.sourceIsolated = true
    let card = try await book.stage(input).proposal.card
    #expect(card.warnings.first == "From the turn.")
    #expect(card.warnings.last == isolatedSourceWarning)
    #expect(card.warnings.count == 3)
  }

  // plan-diagnostics.ts:227: the plan findings follow the untyped warnings, and only a plan pass card carries them
  @Test func shouldAppendAPlanCardsFindingsAfterItsWarnings() async throws {
    let book = try await World.book()
    let finding = ProposalDiagnostic(kind: .known(.density), message: "Density: 1 scene(s) — keep it if that is what you intend.")
    var input = World.input(try World.changeSet(#"{"op":"brief.update","chapter":4,"body":"x"}"#), novel: book.novel, warnings: ["Echo."])
    input.planDiagnostics = [finding]
    input.kind = .chapterPlan
    let card = try await book.stage(input).proposal.card
    #expect(card.diagnostics == [ProposalDiagnostic(kind: .known(.other), message: "Echo."), finding])
    #expect(card.warnings == ["Echo.", finding.message])
    input.kind = .chat
    #expect(try await book.stage(input).proposal.card.diagnostics.count == 1)
  }
}
