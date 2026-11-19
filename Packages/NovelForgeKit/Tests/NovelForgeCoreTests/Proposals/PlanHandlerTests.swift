import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

func briefUpdate(_ json: String) throws -> BriefUpdate {
  guard case .briefUpdate(let update)? = try applyOps(json).first?.operation else { throw PlanHandlerTestError.notABriefUpdate(json) }
  return update
}

enum PlanHandlerTestError: Error {
  case notABriefUpdate(String)
}

extension ChapterBook {
  func livePlan(_ chapter: Int) async throws -> ChapterPlanContent? {
    let novel = novel
    return try await store.read { transaction in
      guard case .readable(let entry) = try ChapterPlanRecord.read(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction), !entry.isRemoved else {
        return nil
      }
      return entry.record.content
    }
  }

  func planRevisions(_ chapter: Int) async throws -> Int {
    let novel = novel
    return try await store.read { try ChapterPlanRecord.history(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: $0).history?.revisions.count ?? 0 }
  }

  func putPlan(_ chapter: Int, _ content: ChapterPlanContent) async throws {
    let novel = novel
    try await run { try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, content, in: &$0) }
  }

  /// The calls in one transaction, then the plan rules over every plan edit they returned and `extra` (what other handlers of the change set wrote).
  func applyChecked(_ calls: [ContentCall], extra: [PlanOverlay.Edit] = [], intent: ApplyIntent = .apply) async throws -> [AppliedStep] {
    let (novel, context) = (novel, applyContext(intent))
    return try await run { transaction in
      var steps = [AppliedStep]()
      for call in calls { steps.append(try ApplyFrame.perform(call, context: context, in: &transaction)) }
      try ApplyFrame.enforcePlanOps(PlanOverlay(steps.flatMap(\.planEdits) + extra), novel: novel, in: transaction)
      return steps
    }
  }

  /// One call through the frame with a raise to unrestricted allowed, as a caller that found it available passes (apply.types.ts:33).
  func perform(_ call: ContentCall, raising: Bool) async throws -> DraftApplyResult {
    var context = applyContext()
    context.unrestrictedRaise = raising
    let allowed = context
    return try await run { transaction in
      do throws(ApplyError) {
        return .success(try ApplyFrame.perform(call, context: allowed, in: &transaction))
      } catch {
        return .failure(error)
      }
    }
  }

  /// Runs `body` and returns the code of the domain refusal that aborted it, nil when it committed.
  func refusalCode(_ body: @escaping BookWrite<Void>) async throws -> String? {
    do {
      try await store.write(body)
      return nil
    } catch {
      guard case .aborted(let cause) = error else { throw error }
      return (cause as? DomainError)?.code ?? (cause as? ApplyError)?.code
    }
  }
}

private func plainBrief() -> ChapterPlanContent {
  ChapterPlanContent(body: "Ada hides the slip.")
}

/// proposal-apply-plan-fields.spec.ts:89
private func plannedBrief() -> ChapterPlanContent {
  var content = plainBrief()
  content.direction = "Ada chooses the ledger over her brother."
  content.contentMode = .known(.unrestricted)
  content.scenes = [PlanScene(BriefScene(summary: "The clerk refuses her.", pov: "ada"))]
  content.contract.claimedMilestones = ["ada_reads_ledger"]
  content.contract.isEnding = true
  return content
}

private struct PlanFields: Equatable {
  let direction: String?
  let contentMode: StoredEnum<ContentMode>?
  let scenes: [BriefScene]?
  let claimed: [String]
  let isEnding: Bool

  init(_ content: ChapterPlanContent?) {
    direction = content?.direction
    contentMode = content?.contentMode
    scenes = content?.scenes?.map(\.scene)
    claimed = content?.contract.claimedMilestones ?? []
    isEnding = content?.contract.isEnding ?? false
  }
}

// apps/novel-forge-server/src/modules/refinement/apply/brief.handler.ts, brief-merge.ts and the plan cases of tests/refinement/proposal-apply-plan-*.spec.ts
@Suite("Plan handlers", TestTimeLimit.standard)
struct PlanHandlerTests {
  // brief-merge.spec.ts:8
  @Test func shouldGiveAPlanItCreatesTheDefaultsItDoesNotName() throws {
    let merged = PlanBriefMerge.merged(
      nil, try briefUpdate(#"{"op":"brief.update","chapter":4,"body":"Mara leaves."}"#), defaults: PlanDefaults(volume: "v1", contentMode: .known(.standard)))
    #expect(merged.body == "Mara leaves.")
    #expect(merged.volume == "v1")
    #expect(merged.contentMode == .known(.standard))
    #expect(merged.contract.isEnding == false)
    #expect(merged.contract.claimedMilestones.isEmpty)
    #expect(merged.handEdited)
  }

  // brief-merge.spec.ts:14
  @Test func shouldKeepAStoredPlansOwnVolumeEvenNoneRatherThanTheDefaults() throws {
    let existing = PlanBriefMerge.merged(
      nil, try briefUpdate(#"{"op":"brief.update","chapter":4,"body":"Mara leaves."}"#), defaults: PlanDefaults(volume: nil, contentMode: .known(.unrestricted)))
    let merged = PlanBriefMerge.merged(
      existing, try briefUpdate(#"{"op":"brief.update","chapter":4,"isEnding":true}"#), defaults: PlanDefaults(volume: "v1", contentMode: .known(.standard)))
    #expect(merged.volume == nil)
    #expect(merged.contentMode == .known(.unrestricted))
    #expect(merged.contract.isEnding)
  }

  // brief-merge.spec.ts:24
  @Test func shouldNormaliseClaimsClearWhatTheOpNullsAndTrimABlankPointOfViewToNone() throws {
    let defaults = PlanDefaults(volume: "v1", contentMode: .known(.standard))
    let existing = PlanBriefMerge.merged(
      nil, try briefUpdate(#"{"op":"brief.update","chapter":4,"body":"x","pov":"mara","knowledgeContract":{"pov":["mara"],"learns":[]}}"#), defaults: defaults)
    let json = #"{"op":"brief.update","chapter":4,"pov":" ","knowledgeContract":null,"claimedMilestones":[" rank_3 ","rank_3"]}"#
    let merged = PlanBriefMerge.merged(existing, try briefUpdate(json), defaults: defaults)
    #expect(merged.pov == nil)
    #expect(merged.contract.pov.isEmpty && merged.contract.learns.isEmpty)
    #expect(merged.contract.claimedMilestones == ["rank_3"])
  }

  // brief.handler.ts:59
  @Test func shouldCreateAPlanOnlyWithABody() async throws {
    let book = try await ChapterBook.make()
    #expect(applyRefusal(try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"title":"The Slip"}"#))) == .notAllowed)
    #expect(try await book.livePlan(3) == nil)
    let step = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"body":""}"#)).get()
    #expect(try await book.livePlan(3)?.body == "")
    #expect(step.inverse == (try inverseObject(#"{"op":"brief.remove","chapter":3}"#)))
  }

  // brief.handler.ts:90
  @Test func shouldRefuseRemovingAPlanThatIsNotThereAsRFN004() async throws {
    let book = try await ChapterBook.make()
    #expect(applyRefusal(try await book.perform(try draftCall(#"{"op":"brief.remove","chapter":3}"#))) == .notAllowed)
  }

  // proposal-apply-plan-rules.spec.ts:98 and brief.handler.ts:46: the reference also refuses behind its story cursor, which here never passes the latest
  // final chapter
  @Test func shouldRefuseEveryPlanWriteAtOrBehindTheLatestFinalChapterIncludingAnUndo() async throws {
    let book = try await ChapterBook.make()
    try await book.finalized(through: 2)
    let before = try await book.livePlan(2)
    for json in [
      #"{"op":"brief.update","chapter":2,"body":"Mira falls."}"#, #"{"op":"brief.remove","chapter":2}"#, #"{"op":"brief.update","chapter":1,"title":"Again"}"#,
    ] {
      #expect(applyRefusal(try await book.perform(try draftCall(json))) == .planClosed(chapter: json.contains(#""chapter":1"#) ? 1 : 2), "\(json)")
    }
    let restore = try #require(before.map { BriefRestore($0, chapter: 2).json })
    let undo = try await book.undo(restore, of: try draftCall(#"{"op":"brief.remove","chapter":2}"#), through: .plan)
    #expect(applyRefusal(undo) == .planClosed(chapter: 2))
    #expect(try await book.livePlan(2) == before)
  }

  // proposal-apply-plan-fields.spec.ts:140, :147: a raise the caller did not allow is refused (unrestricted-raise.ts:25)
  @Test func shouldRefuseRaisingAPlanToUnrestrictedButLetAnUnrestrictedOneKeepItsMode() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, plainBrief())
    #expect(applyRefusal(try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"contentMode":"unrestricted"}"#))) == .unrestrictedUnavailable)
    #expect(try await book.livePlan(3)?.contentMode == nil)
    let create = #"{"op":"brief.update","chapter":4,"body":"x","contentMode":"unrestricted"}"#
    #expect(applyRefusal(try await book.perform(try draftCall(create))) == .unrestrictedUnavailable)
    _ = try await book.perform(try draftCall(create), raising: true).get()
    #expect(try await book.livePlan(4)?.contentMode == .known(.unrestricted))

    try await book.putPlan(3, plannedBrief())
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"title":"The Slip","contentMode":"unrestricted"}"#)).get()
    #expect(try await book.livePlan(3)?.contentMode == .known(.unrestricted))
  }

  // proposal-apply-plan-fields.spec.ts:147, :158: an undo puts an unrestricted mode back; a redo of a raise is refused like the apply
  @Test func shouldLetAnUndoRestoreUnrestrictedAndRefuseARedoThatRaisesIt() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, plannedBrief())
    let lower = try draftCall(#"{"op":"brief.update","chapter":3,"contentMode":"standard"}"#)
    let lowered = try await book.perform(lower).get()
    let lowering = try #require(lowered.inverse)
    _ = try await book.undo(lowering, of: lower, through: .plan).get()
    #expect(try await book.livePlan(3)?.contentMode == .known(.unrestricted))

    try await book.putPlan(3, plainBrief())
    let raise = try draftCall(#"{"op":"brief.update","chapter":3,"contentMode":"unrestricted"}"#)
    #expect(applyRefusal(try await book.perform(raise, intent: .redo)) == .unrestrictedUnavailable)
    #expect(try await book.livePlan(3)?.contentMode == nil)
  }

  // proposal-apply-volumes.spec.ts:141, :154
  @Test func shouldPutANewPlanIntoTheVolumeOfTheNearestEarlierPlanAndKeepAStoredPlansNone() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(2, ChapterPlanContent(body: "Ada meets the clerk.", volume: "volume_1"))
    try await book.putPlan(4, ChapterPlanContent(body: "Ada steals the slip."))
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":5,"body":"Ada reaches the Assize."}"#)).get()
    #expect(try await book.livePlan(5)?.volume == "volume_1")
    try await book.putPlan(3, ChapterPlanContent(body: "Ada hides the slip."))
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"title":"The Slip"}"#)).get()
    #expect(try await book.livePlan(3)?.volume == nil)
    #expect(try await book.livePlan(3)?.title == "The Slip")
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":1,"body":"Before it all."}"#)).get()
    #expect(try await book.livePlan(1)?.volume == "volume_1")
  }

  // brief-volume.ts:12 reads the plans the same transaction already wrote
  @Test func shouldTakeTheVolumeOfAPlanAnEarlierChangeOfTheSameApplyWrote() async throws {
    let book = try await ChapterBook.make()
    let calls = [try draftCall(#"{"op":"brief.update","chapter":4,"body":"x","volumeKey":"volume_2"}"#), try draftCall(#"{"op":"brief.update","chapter":5,"body":"y"}"#)]
    _ = try await book.applyChecked(calls)
    #expect(try await book.livePlan(5)?.volume == "volume_2")
  }

  @Test func shouldRefuseANewPlanWithoutAVolumeOnlyWhenAnUnreadablePlanCouldBeTheNearest() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.putPlan(2, ChapterPlanContent(body: "Ada meets the clerk.", volume: "volume_1"))
    let ref = try ChapterPlanRecord.ref(novel: novel, chapter: 4)
    let key = try NovelForgeKey(novel: novel, .chapterPlan(chapter: 4))
    try await book.run { transaction in
      _ = try transaction.set(ref, ["natural_key": key.stored, "removed": .bool(false)])
      _ = try transaction.revise(ref, body: .object(["body": .int(1)]))
    }
    let blocked = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":5,"body":"y"}"#))
    #expect(throws: ApplyError.unreadable(ref: "chapter:4")) { try blocked.get() }
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"body":"z"}"#)).get()
    #expect(try await book.livePlan(3)?.volume == "volume_1")
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":6,"body":"w","volumeKey":"volume_3"}"#)).get()
    #expect(try await book.livePlan(6)?.volume == "volume_3")
  }

  // brief-volume.ts:10 reads the briefs that stand: a removed plan, whether an earlier apply or this one removed it, lends no volume
  @Test(arguments: [false, true])
  func shouldSkipARemovedPlanWhenChoosingTheVolumeOfANewOne(_ removedInTheSameApply: Bool) async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(2, ChapterPlanContent(body: "Ada meets the clerk.", volume: "volume_1"))
    try await book.putPlan(4, ChapterPlanContent(body: "Ada steals the slip.", volume: "volume_2"))
    let removal = try draftCall(#"{"op":"brief.remove","chapter":4}"#)
    let create = try draftCall(#"{"op":"brief.update","chapter":5,"body":"Ada reaches the Assize."}"#)
    if removedInTheSameApply {
      _ = try await book.applyChecked([removal, create])
    } else {
      _ = try await book.perform(removal).get()
      _ = try await book.perform(create).get()
    }
    #expect(try await book.livePlan(5)?.volume == "volume_1")
  }

  @Test func shouldRefuseANewPlanWithoutAVolumeWhileAPlanWhoseNovelCannotBeReadStands() async throws {
    let book = try await ChapterBook.make()
    let ref = EntityRef(kind: NovelForgeKind.chapterPlan.entityKind, key: try #require(EntityKey("garbage")))
    try await book.run { transaction in
      _ = try transaction.set(ref, ["natural_key": .string("garbage"), "removed": .bool(false)])
      _ = try transaction.revise(ref, body: .object(["body": .string("x")]))
    }
    let blocked = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":5,"body":"y"}"#))
    #expect(throws: ApplyError.unreadable(ref: "\(ref.kind.rawValue)/garbage")) { try blocked.get() }
    #expect(try await book.livePlan(5) == nil)
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":5,"body":"y","volumeKey":"volume_1"}"#)).get()
    #expect(try await book.livePlan(5)?.volume == "volume_1")
  }

  // brief-volume.ts:12 reads chapter 3's plan; the plan world holds its unreadable canon instead, so the volume the plan names is unknown here
  @Test func shouldRefuseANewPlanWithoutAVolumeWhenAFinalChapterNearerThanTheRestHasAnUnreadableCanon() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.putPlan(1, ChapterPlanContent(body: "Ada meets the clerk.", volume: "volume_1"))
    try await book.putPlan(3, ChapterPlanContent(body: "Ada steals the slip.", volume: "volume_3"))
    let key = try NovelForgeKey(novel: novel, .finalChapter(chapter: 3))
    try await book.run { _ = try $0.set(key.ref, ["natural_key": key.stored, "canon": "broken"]) }
    let blocked = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":4,"body":"Ada reaches the Assize."}"#))
    #expect(throws: ApplyError.unreadable(ref: "chapter:3")) { try blocked.get() }
    #expect(try await book.livePlan(4) == nil)
  }

  @Test(arguments: [true, false])
  func shouldRefuseANewPlanWithoutAVolumeWhileTheRecordIndexIsFaultedOnAPlan(_ onAPlanKey: Bool) async throws {
    let book = try await ChapterBook.make()
    let ref = try ChapterPlanRecord.ref(novel: book.novel, chapter: 9)
    let key = onAPlanKey ? ProjectionFaults.key(ref) : "an undecodable key"
    try await book.store.write { transaction in
      try transaction.database.execute(
        sql: "INSERT INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES (?, ?, 1, 'planted')", arguments: [IndexedRecord.databaseTableName, key])
    }
    let outcome = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":4,"body":"y"}"#), faulted: true)
    #expect(throws: ApplyError.domain(.planStateUnavailable(4))) { try outcome.get() }
    // a fault on a plan key leaves the plan world standing, so only the volume default is refused; an undecodable one stops every plan write
    let named = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":4,"body":"y","volumeKey":"volume_1"}"#), faulted: true)
    #expect(((try? named.get()) != nil) == onAPlanKey)
  }

  // brief.handler.ts:65 (defaultChapterMode): a new plan takes the novel's mode unless the op names one, null included
  @Test func shouldStartANewPlanInTheNovelsContentMode() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      var edit = NovelEdit()
      edit.contentMode = .set(.known(.unrestricted))
      try transaction.edit(NovelRecord.self, NovelForgeKey.novel(novel), edit.fields)
    }
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"body":"x"}"#)).get()
    #expect(try await book.livePlan(3)?.contentMode == .known(.unrestricted))
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":4,"body":"x","contentMode":null}"#)).get()
    #expect(try await book.livePlan(4)?.contentMode == nil)
  }

  // proposal-apply-plan-fields.spec.ts:105
  @Test func shouldSetEveryPlanFieldAndRestoreTheUnsetValuesOnUndo() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, plainBrief())
    let json = #"""
      {"op":"brief.update","chapter":3,"direction":"  Ada chooses the ledger over her brother. ","contentMode":"unrestricted",
       "scenes":[{"summary":"The clerk refuses her.","pov":"ada"},{"summary":"Night at the docks."}],"claimedMilestones":["ada_reads_ledger"," ada_reads_ledger "],"isEnding":true}
      """#
    let call = try draftCall(json)
    let applied = try await book.perform(call, raising: true).get()
    let written = try #require(try await book.livePlan(3))
    #expect(written.direction == "Ada chooses the ledger over her brother.")
    #expect(written.contentMode == .known(.unrestricted))
    #expect(written.scenes?.map(\.scene) == [BriefScene(summary: "The clerk refuses her.", pov: "ada"), BriefScene(summary: "Night at the docks.")])
    #expect(written.contract.claimedMilestones == ["ada_reads_ledger"])
    #expect(written.contract.isEnding)
    let inverse = try #require(applied.inverse)
    for key in ["direction", "contentMode", "scenes", "claimedMilestones"] { #expect(inverse[key] == .null, "\(key)") }
    #expect(inverse["isEnding"] == .bool(false))
    _ = try await book.undo(inverse, of: call, through: .plan).get()
    #expect(PlanFields(try await book.livePlan(3)) == PlanFields(plainBrief()))
  }

  // proposal-apply-plan-fields.spec.ts:169
  @Test func shouldKeepEveryPlanFieldAnOpLeavesOut() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, plannedBrief())
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"title":"The Slip"}"#)).get()
    #expect(PlanFields(try await book.livePlan(3)) == PlanFields(plannedBrief()))
  }

  // proposal-apply-plan-fields.spec.ts:177
  @Test func shouldClearThePlanFieldsAnOpSetsToNullAndPutThemBackOnUndo() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, plannedBrief())
    let call = try draftCall(#"{"op":"brief.update","chapter":3,"direction":null,"contentMode":null,"scenes":null,"claimedMilestones":null,"isEnding":false}"#)
    let applied = try await book.perform(call).get()
    #expect(PlanFields(try await book.livePlan(3)) == PlanFields(plainBrief()))
    _ = try await book.undo(applied.inverse, of: call, through: .plan).get()
    #expect(PlanFields(try await book.livePlan(3)) == PlanFields(plannedBrief()))
  }

  // proposal-apply-plan-card.spec.ts:40
  @Test func shouldRenderThePlanBodyFromTheScenesTheWriteCarries() async throws {
    let book = try await ChapterBook.make()
    let json = #"""
      {"op":"brief.update","chapter":3,"body":"Mara tests the lamp.\nScene 1 (~900 words). Stale line from staging.",
       "scenes":[{"summary":"Mara bargains at the gate","pov":"mara","goal":"Get through","turn":"The gate opens","estimatedWords":900},{"summary":"Ren waits below","pov":"ren"}]}
      """#
    _ = try await book.perform(try draftCall(json)).get()
    let expected = [
      "Mara tests the lamp.", "Scene 1 (~900 words). Mara bargains at the gate. Goal: Get through. Turn: The gate opens. POV: mara.", "Scene 2. Ren waits below. POV: ren.",
    ].joined(separator: "\n")
    #expect(try await book.livePlan(3)?.body == expected)
  }

  // proposal-apply-plan-card.spec.ts:62, :73
  @Test func shouldStripTheScenesWhenTheListIsEmptiedAndKeepAHandWrittenBodyWithoutScenes() async throws {
    let book = try await ChapterBook.make()
    let json = #"{"op":"brief.update","chapter":3,"body":"Mara tests the lamp.","scenes":[{"summary":"Ren waits below","pov":"ren"}]}"#
    _ = try await book.perform(try draftCall(json)).get()
    #expect(try await book.livePlan(3)?.body.contains("Scene 1. Ren waits below. POV: ren.") == true)
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"scenes":[]}"#)).get()
    #expect(try await book.livePlan(3)?.body == "Mara tests the lamp.")
    _ = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":4,"body":"Written by hand.\n\nScene 1 is mine."}"#)).get()
    #expect(try await book.livePlan(4)?.body == "Written by hand.\n\nScene 1 is mine.")
  }

  // proposal-apply-plan-card.spec.ts:82
  @Test func shouldClearAReplacedPlansPointOfViewWriteThePlannersRisksAndBringBothBackOnUndo() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, ChapterPlanContent(body: "Old plan.", pov: "mara", repetitionRisks: ["old"], densityRisk: "old risk"))
    let call = try draftCall(#"{"op":"brief.update","chapter":3,"body":"New plan.","pov":null,"repetitionRisks":null,"densityRisk":"Thin material"}"#)
    let applied = try await book.perform(call).get()
    let written = try #require(try await book.livePlan(3))
    #expect(written.pov == nil && written.repetitionRisks == nil && written.densityRisk == "Thin material")
    _ = try await book.undo(applied.inverse, of: call, through: .plan).get()
    let restored = try #require(try await book.livePlan(3))
    #expect(restored.pov == "mara" && restored.repetitionRisks == ["old"] && restored.densityRisk == "old risk")
  }

  // proposal-apply-volumes.spec.ts:73, :91, :107 (the plan halves; the volume ops are the story handlers')
  @Test func shouldTakeAMovedPlanBackOutOfItsVolumeAndRemoveACreatedOneOnUndo() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, ChapterPlanContent(body: "Ada hides the slip."))
    let move = try draftCall(#"{"op":"brief.update","chapter":3,"volumeKey":"volume_2"}"#)
    let moved = try await book.perform(move).get()
    #expect(try await book.livePlan(3)?.volume == "volume_2")
    _ = try await book.undo(moved.inverse, of: move, through: .plan).get()
    #expect(try await book.livePlan(3)?.volume == nil)

    let create = try draftCall(#"{"op":"brief.update","chapter":1,"body":"Ada meets the clerk.","volumeKey":"volume_1"}"#)
    let created = try await book.perform(create).get()
    #expect(try await book.livePlan(1)?.volume == "volume_1")
    let undone = try await book.undo(created.inverse, of: create, through: .plan).get()
    #expect(try await book.livePlan(1) == nil)
    #expect(undone.planEdits == [.planRemoved(chapter: 1)])
  }

  @Test func shouldReturnEachPlanAsWritten() async throws {
    let book = try await ChapterBook.make()
    let ref = try ChapterPlanRecord.ref(novel: book.novel, chapter: 3)
    let created = try await book.perform(try draftCall(#"{"op":"brief.update","chapter":3,"body":"x","claimedMilestones":["rise"]}"#)).get()
    #expect(created.planEdits == [.plan(chapter: 3, ref: ref, content: try #require(try await book.livePlan(3)))])
    let removed = try await book.perform(try draftCall(#"{"op":"brief.remove","chapter":3}"#)).get()
    #expect(removed.planEdits == [.planRemoved(chapter: 3)])
    let restored = try await book.undo(removed.inverse, of: try draftCall(#"{"op":"brief.remove","chapter":3}"#), through: .plan).get()
    #expect(restored.planEdits == [.plan(chapter: 3, ref: ref, content: try #require(try await book.livePlan(3)))])
  }

  // brief.handler.ts:71 always writes; here an unchanged plan gets no revision, yet the plan rules still judge it
  @Test func shouldWriteNoRevisionForAnUnchangedPlanButStillReturnIt() async throws {
    let book = try await ChapterBook.make()
    let call = try draftCall(#"{"op":"brief.update","chapter":3,"body":"x","title":"T"}"#)
    _ = try await book.perform(call).get()
    let before = try await book.planRevisions(3)
    let again = try await book.perform(call).get()
    #expect(try await book.planRevisions(3) == before)
    #expect(again.planEdits.count == 1)
  }

  // proposal-revert.service.ts:148 writes the captured fields back; here they are written verbatim, so nothing the merge would trim or render moves
  @Test func shouldUndoToThePlanExactlyAsItWasWithNoneOfTheMergesNormalising() async throws {
    let book = try await ChapterBook.make()
    var seed = ChapterPlanContent(body: "Scene 1. Edited by hand.", pov: " mara ", guidance: "Slow down.", direction: " Up. ", scenes: [PlanScene(BriefScene(summary: " x "))])
    seed.handEdited = false
    try await book.putPlan(3, seed)
    let call = try draftCall(#"{"op":"brief.update","chapter":3,"title":"T","pov":"ren","scenes":[{"summary":"y"}]}"#)
    let applied = try await book.perform(call).get()
    _ = try await book.undo(applied.inverse, of: call, through: .plan).get()
    let restored = try #require(try await book.livePlan(3))
    #expect(sameRevision(restored, seed), "\(restored)")
  }

  @Test func shouldBringARemovedPlanBackWithTheGuidanceItsInverseDoesNotName() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, ChapterPlanContent(body: "x", guidance: "Slow down."))
    let call = try draftCall(#"{"op":"brief.remove","chapter":3}"#)
    let removed = try await book.perform(call).get()
    _ = try await book.undo(removed.inverse, of: call, through: .plan).get()
    #expect(try await book.livePlan(3)?.guidance == "Slow down.")
  }

  @Test(arguments: [
    #"{"op":"brief.update","chapter":5,"body":"A new plan.","scenes":[{"summary":"One"}]}"#,
    #"{"op":"brief.update","chapter":3,"title":"T","volumeKey":"v2","pov":" ren ","knowledgeContract":{"pov":["mara"],"learns":[{"entityKey":"mara","factKey":"heir"}]}}"#,
    #"{"op":"brief.update","chapter":3,"body":"B","scenes":null,"claimedMilestones":["rise"],"isEnding":true,"writeMode":"external","densityRisk":"Thin"}"#,
    #"{"op":"brief.remove","chapter":3}"#,
  ])
  func shouldRestoreThePlanContentThroughApplyUndoRedoUndo(_ json: String) async throws {
    let book = try await ChapterBook.make()
    var seed = ChapterPlanContent(body: "Old.", volume: "v1", guidance: "Slow down.", scenes: [PlanScene(BriefScene(summary: "Old scene"))])
    seed.contract.pov = ["mara"]
    try await book.putPlan(3, seed)
    try await expectContentRoundTrip(book, try draftCall(json), through: .plan)
  }

  @Test func shouldRestoreAPlanAnApplyRecreatesOverItsRemovalThroughApplyUndoRedoUndo() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, ChapterPlanContent(body: "Old.", guidance: "Slow down."))
    _ = try await book.perform(try draftCall(#"{"op":"brief.remove","chapter":3}"#)).get()
    try await expectContentRoundTrip(book, try draftCall(#"{"op":"brief.update","chapter":3,"body":"Again."}"#), through: .plan)
  }

  @Test(arguments: [
    #"{"op":"brief.update","chapter":3}"#, #"{"op":"brief.remove","chapter":0}"#, #"{"op":"brief.remove"}"#, #"{"op":"entity.remove","entityKey":"mara"}"#,
  ])
  func shouldRefuseAnInverseItCannotRead(_ json: String) async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(3, plainBrief())
    let outcome = try await book.undo(try inverseObject(json), of: try draftCall(#"{"op":"brief.remove","chapter":3}"#), through: .plan)
    #expect(applyRefusal(outcome) == .malformedInverse)
    #expect(try await book.livePlan(3) != nil)
  }

  // staged-plan.ts:15: merged in memory, a content mode left out stays unset, nothing written
  @Test func shouldStageAPlanWithoutWritingIt() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.putPlan(2, ChapterPlanContent(body: "Ada meets the clerk.", volume: "volume_1"))
    let update = try briefUpdate(#"{"op":"brief.update","chapter":5,"body":"Ada reaches the Assize.","claimedMilestones":[" rise "]}"#)
    let (staged, written) = try await book.store.write { transaction in (try PlanHandlers.stagedPlan(update, novel: novel, in: transaction), transaction.changes.count) }
    #expect(written == 0)
    #expect(staged.volume == "volume_1")
    #expect(staged.contentMode == nil)
    #expect(staged.contract.claimedMilestones == ["rise"])
    #expect(try await book.livePlan(5) == nil)
  }
}

// apps/novel-forge-server/src/modules/refinement/apply/apply-rules.ts:46 over the plan edits the handlers return, and tests/refinement/proposal-apply-plan-rules.spec.ts
@Suite("Plan handlers: the plan rules over the written plans", TestTimeLimit.standard)
struct PlanHandlerRuleTests {
  // proposal-apply-plan-rules.spec.ts:33
  @Test func shouldRefuseAPlanThatRevealsALockedFactAsPLN001() async throws {
    let book = try await ChapterBook.make()
    try await book.putPlan(2, ChapterPlanContent(body: "Mira climbs."))
    let call = try draftCall(#"{"op":"brief.update","chapter":2,"knowledgeContract":{"pov":["mara"],"learns":[{"entityKey":"mara","factKey":"tide"}]}}"#)
    let context = book.applyContext()
    let novel = book.novel
    let code = try await book.refusalCode { transaction in
      let step = try ApplyFrame.perform(call, context: context, in: &transaction)
      try ApplyFrame.enforcePlanOps(PlanOverlay(step.planEdits), novel: novel, in: transaction)
    }
    #expect(code == "PLN_001")
    #expect(try await book.livePlan(2)?.contract.learns.isEmpty == true)
  }

  // proposal-apply-plan-rules.spec.ts:89
  @Test func shouldRefuseASecondEndingPlanAsPLN002() async throws {
    let book = try await ChapterBook.make()
    var ending = ChapterPlanContent(body: "The last light.")
    ending.contract.isEnding = true
    try await book.putPlan(40, ending)
    let call = try draftCall(#"{"op":"brief.update","chapter":41,"body":"After the last light.","isEnding":true}"#)
    let context = book.applyContext()
    let novel = book.novel
    let code = try await book.refusalCode { transaction in
      let step = try ApplyFrame.perform(call, context: context, in: &transaction)
      try ApplyFrame.enforcePlanOps(PlanOverlay(step.planEdits), novel: novel, in: transaction)
    }
    #expect(code == "PLN_002")
    #expect(try await book.livePlan(41) == nil)
  }

  @Test(arguments: [
    #"{"op":"brief.update","chapter":3,"body":"x","claimedMilestones":["nowhere"]}"#, #"{"op":"brief.update","chapter":3,"body":"x","claimedMilestones":["rise"]}"#,
  ])
  func shouldRefuseAClaimThePlanCannotMakeAsPLN003(_ json: String) async throws {
    let book = try await ChapterBook.make()
    var claimant = ChapterPlanContent(body: "Mara rises.")
    claimant.contract.claimedMilestones = ["rise"]
    try await book.putPlan(4, claimant)
    let call = try draftCall(json)
    let context = book.applyContext()
    let novel = book.novel
    let code = try await book.refusalCode { transaction in
      let step = try ApplyFrame.perform(call, context: context, in: &transaction)
      try ApplyFrame.enforcePlanOps(PlanOverlay(step.planEdits), novel: novel, in: transaction)
    }
    #expect(code == "PLN_003")
  }

  // proposal-apply-plan-rules.spec.ts:57: the milestone op is the story handlers'; its overlay edit stands in for it here
  @Test func shouldAcceptAPlanThatClaimsAMilestoneTheChangeSetCreatesAndRevealsTheFactItUnlocks() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      let unlock = JSONValue.object(["all": .array([.object(["milestone": .string("lamp_rank_4")])])])
      try PlanWorldWrites.secret(novel: novel, "lamp_rank_4_rule", unlock: unlock, in: &transaction)
    }
    try await book.putPlan(5, ChapterPlanContent(body: "Mira climbs."))
    let json =
      #"{"op":"brief.update","chapter":5,"knowledgeContract":{"pov":["mara"],"learns":[{"entityKey":"mara","factKey":"lamp_rank_4_rule"}]},"claimedMilestones":["lamp_rank_4"]}"#
    let call = try draftCall(json)
    let context = book.applyContext()
    let refused = try await book.refusalCode { transaction in
      let step = try ApplyFrame.perform(call, context: context, in: &transaction)
      try ApplyFrame.enforcePlanOps(PlanOverlay(step.planEdits), novel: novel, in: transaction)
    }
    #expect(refused == "PLN_003")
    try await book.run { transaction in
      try Milestones.create(novel: novel, milestone: "lamp_rank_4", label: "Mira reaches the fourth rank", subject: nil, kind: .known(.rank), in: &transaction)
    }
    _ = try await book.applyChecked([call], extra: [.milestone("lamp_rank_4")])
    #expect(try await book.livePlan(5)?.contract.claimedMilestones == ["lamp_rank_4"])
  }

  // proposal-apply-plan-rules.spec.ts:70: an undo's plan is judged as the world stands, so one whose reveal no longer holds is refused
  @Test func shouldRefuseAnUndoBackToAPlanWhoseRevealNoLongerHolds() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      let unlock = JSONValue.object(["all": .array([.object(["milestone": .string("rise")])])])
      try PlanWorldWrites.secret(novel: novel, "rise_rule", unlock: unlock, in: &transaction)
    }
    try await book.plan(4, claims: ["rise"])
    try await book.plan(5, learns: [reveal("mara", "rise_rule")])
    let dropReveal = try draftCall(#"{"op":"brief.update","chapter":5,"knowledgeContract":null}"#)
    let dropped = try #require(try await book.applyChecked([dropReveal]).first)
    _ = try await book.applyChecked([try draftCall(#"{"op":"brief.update","chapter":4,"claimedMilestones":null}"#)])
    let inverse = try #require(dropped.inverse)
    let context = book.applyContext(.undo)
    let code = try await book.refusalCode { transaction in
      let step = try ApplyFrame.perform(dropReveal, context: context, in: &transaction) { _, context, transaction throws(ApplyError) in
        try PlanHandlers.undo(inverse, context: context, in: &transaction)
      }
      try ApplyFrame.enforcePlanOps(PlanOverlay(step.planEdits), novel: novel, in: transaction)
    }
    #expect(code == "PLN_001")
    #expect(try await book.livePlan(5)?.contract.learns.isEmpty == true)
  }
}
