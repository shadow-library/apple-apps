import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private func storyPlan(_ chapter: Int, learns: [KnowledgeReveal] = [], claims: [String] = [], volume: String? = nil) throws -> PlanOverlay.Edit {
  let contract = ChapterContract(pov: ["mara"], learns: learns.map(ContractLearn.init), claimedMilestones: claims)
  let content = ChapterPlanContent(body: "The plan.", volume: volume, contract: contract)
  return .plan(chapter: chapter, ref: try ChapterPlanRecord.ref(novel: SchemaFixture.novel, chapter: chapter), content: content)
}

private func applied(_ json: String, in transaction: inout WriteTransaction) throws -> [PlanOverlay.Edit] {
  try ApplyFrame.perform(.op(try storyOp(json)), context: storyApplyContext, in: &transaction).planEdits
}

private func unreadable(_ components: NovelForgeKey.Components, in transaction: inout WriteTransaction) throws {
  let key = try NovelForgeKey(novel: SchemaFixture.novel, components)
  _ = try transaction.set(key.ref, ["natural_key": key.stored, "removed": .bool(false)])
}

private func unreadableHead(_ record: some KeyedRecord, in world: StoryWorld) async throws {
  try await world.seed(record)
  let ref = record.ref
  try await world.run { _ = try $0.revise(ref, body: .object(["body": .int(1)])) }
}

// apps/novel-forge-server/src/modules/refinement/apply/apply-rules.ts:46: the facts, milestones and volumes a change set writes reach the plan check through the
// overlay, since the plan world is derived only after the commit
@Suite("Story handlers: plan edits through the overlay")
struct StoryHandlerOverlayTests {
  @Test func shouldJudgeAPlanAgainstTheFactAsTheHandlerWroteIt() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      let edits = try applied(#"{"op":"fact.upsert","factKey":"tide","revealChapter":2}"#, in: &transaction)
      let written = try #require(live(try SecretRecord.read(novel: novel, secret: "tide", in: transaction)))
      #expect(edits == [.fact(DisclosureFact(secret: written, disclosedInChapter: nil))])
      try ApplyFrame.enforcePlanOps(PlanOverlay(edits + [try storyPlan(2, learns: [reveal("mara", "tide")])]), novel: novel, in: transaction)
    }
    await book.expect(.planRevealsLocked(chapter: 2, violations: "tide (needs chapter 9 or later)")) { transaction in
      let edits = try applied(#"{"op":"fact.upsert","factKey":"tide","revealChapter":9}"#, in: &transaction)
      try ApplyFrame.enforcePlanOps(PlanOverlay([try storyPlan(2, learns: [reveal("mara", "tide")])] + edits), novel: novel, in: transaction)
    }
  }

  // proposal-apply-plan-rules.spec.ts:57
  @Test func shouldAcceptAChangeSetThatCreatesTheMilestoneClaimsItAndRevealsTheFactItUnlocksInAnyOrder() async throws {
    let plan = try storyPlan(5, learns: [reveal("mara", "lamp_rank_4_rule")], claims: ["lamp_rank_4"])
    for planFirst in [true, false] {
      let book = try await ChapterBook.make()
      let novel = book.novel
      try await book.run { transaction in
        let unlock = JSONValue.object(["all": .array([.object(["milestone": .string("lamp_rank_4")])])])
        try PlanWorldWrites.secret(novel: novel, "lamp_rank_4_rule", unlock: unlock, in: &transaction)
      }
      await book.expect(.planClaims(chapter: 5, reason: "lamp_rank_4 is not a milestone of this novel")) { transaction in
        try ApplyFrame.enforcePlanOps(PlanOverlay([plan]), novel: novel, in: transaction)
      }
      try await book.run { transaction in
        let edits = try applied(#"{"op":"milestone.upsert","milestoneKey":"lamp_rank_4","label":"Mira reaches the fourth rank","kind":"rank"}"#, in: &transaction)
        #expect(edits == [.milestone("lamp_rank_4")])
        try ApplyFrame.enforcePlanOps(PlanOverlay(planFirst ? [plan] + edits : edits + [plan]), novel: novel, in: transaction)
      }
    }
  }

  @Test func shouldRefuseAPlanClaimingAMilestoneTheChangeSetRemoves() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    await book.expect(.planClaims(chapter: 3, reason: "rise is not a milestone of this novel")) { transaction in
      let edits = try applied(#"{"op":"milestone.remove","milestoneKey":"rise"}"#, in: &transaction)
      #expect(edits == [.milestoneRemoved("rise")])
      try ApplyFrame.enforcePlanOps(PlanOverlay([try storyPlan(3, claims: ["rise"])] + edits), novel: novel, in: transaction)
    }
  }

  @Test func shouldJudgeAVolumeGatedRevealAgainstTheVolumesTheHandlersWrote() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      try PlanWorldWrites.secret(novel: novel, "vault", unlock: .object(["all": .array([.object(["volume": .string("v2")])])]), in: &transaction)
    }
    let gated = try storyPlan(3, learns: [reveal("mara", "vault")], volume: "v2")
    try await book.run { transaction in
      let edits = try applied(#"{"op":"volume.upsert","volumeKey":"v2","ordinal":2,"title":"The Far Shore"}"#, in: &transaction)
      #expect(edits == [.volume("v2", ordinal: 2)])
      try ApplyFrame.enforcePlanOps(PlanOverlay(edits + [gated]), novel: novel, in: transaction)
    }
    await book.expect(.planRevealsLocked(chapter: 3, violations: "vault (needs volume v2 reached)")) { transaction in
      let edits = try applied(#"{"op":"volume.remove","volumeKey":"v2"}"#, in: &transaction)
      #expect(edits == [.volumeRemoved("v2")])
      try ApplyFrame.enforcePlanOps(PlanOverlay([gated] + edits), novel: novel, in: transaction)
    }
  }

  @Test func shouldReturnTheOverlayEditOfAnUndoAsWritten() async throws {
    let world = try await StoryWorld.make(reconciled: true)
    try await world.seed(VolumeRecord(novel: world.novel, volume: "v1", ordinal: 4), MilestoneRecord(novel: world.novel, milestone: "rise", label: "Rise"))
    for json in [#"{"op":"volume.remove","volumeKey":"v1"}"#, #"{"op":"milestone.remove","milestoneKey":"rise"}"#] {
      let op = try storyOp(json)
      let step = try await world.apply(op).get()
      let undone = try await world.undo(op, try #require(step.inverse)).get()
      #expect(undone.planEdits == (op.type == .volumeRemove ? [.volume("v1", ordinal: 4)] : [.milestone("rise")]))
    }
    let op = try storyOp(#"{"op":"fact.upsert","factKey":"f","body":"B.","revealChapter":3}"#)
    let step = try await world.apply(op).get()
    #expect(try await world.undo(op, try #require(step.inverse)).get().planEdits == [.factRemoved("f")])
  }

  @Test func shouldKeyEveryOverlayEditInNormalForm() async throws {
    let world = try await StoryWorld.make(reconciled: true)
    let decomposed = "cafe\u{301}"
    let composed = "caf\u{E9}"
    let cases: [(String, PlanOverlay.Edit)] = [
      (#"{"op":"milestone.upsert","milestoneKey":"\#(decomposed)","label":"L"}"#, .milestone(composed)),
      (#"{"op":"volume.upsert","volumeKey":"\#(decomposed)","ordinal":1}"#, .volume(composed, ordinal: 1)),
      (#"{"op":"volume.remove","volumeKey":"\#(decomposed)"}"#, .volumeRemoved(composed)),
      (#"{"op":"milestone.remove","milestoneKey":"\#(decomposed)"}"#, .milestoneRemoved(composed)),
      (#"{"op":"fact.upsert","factKey":"\#(decomposed)","body":"B."}"#, .fact(DisclosureFact(factKey: composed, text: "B.", source: .manual))),
      (#"{"op":"fact.remove","factKey":"\#(decomposed)"}"#, .factRemoved(composed)),
    ]
    for (json, edit) in cases {
      let edits = try await world.apply(try storyRawOp(json)).get().planEdits
      #expect(edits == [edit], "\(json)")
      #expect(edits.map(overlayKey).allSatisfy { $0.map { JSString($0) == JSString(composed) } ?? false }, "\(json) keys its edit by code units")
    }
  }
}

/// Swift's String equality is canonical, so a key's code units are compared through JSString.
private func overlayKey(_ edit: PlanOverlay.Edit) -> String? {
  switch edit {
  case .milestone(let key), .milestoneRemoved(let key), .factRemoved(let key), .volumeRemoved(let key), .volume(let key, _): key
  case .fact(let fact): fact.factKey
  case .plan, .planRemoved: nil
  }
}

// apps/novel-forge-server/src/modules/refinement/artifact-state.ts rule (F11a): a record this device cannot read never counts as absent
@Suite("Story handlers: records this device cannot read")
struct StoryHandlerUnreadableTests {
  @Test func shouldRefuseRemovingAVolumeWhileAChapterPlanCannotBeRead() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(VolumeRecord(novel: world.novel, volume: "v1", ordinal: 1))
    try await unreadableHead(try world.plan(chapter: 4), in: world)
    let refusal = ApplyRefusal.unreadableReferences(kind: NovelForgeKind.chapterPlan.rawValue, count: 1)
    try await world.refuses(#"{"op":"volume.remove","volumeKey":"v1"}"#, with: ApplyError.refused(refusal))
  }

  @Test func shouldRefuseRemovingAMilestoneWhileAPlanOrAFactCannotBeRead() async throws {
    let secretWorld = try await StoryWorld.make()
    try await secretWorld.seed(MilestoneRecord(novel: secretWorld.novel, milestone: "rise", label: "Rise"))
    try await secretWorld.run { try unreadable(.secret("broken"), in: &$0) }
    let refusal = ApplyRefusal.unreadableReferences(kind: NovelForgeKind.secret.rawValue, count: 1)
    try await secretWorld.refuses(#"{"op":"milestone.remove","milestoneKey":"rise"}"#, with: ApplyError.refused(refusal))
    let planWorld = try await StoryWorld.make()
    try await planWorld.seed(MilestoneRecord(novel: planWorld.novel, milestone: "rise", label: "Rise"))
    try await unreadableHead(try planWorld.plan(chapter: 2), in: planWorld)
    let planRefusal = ApplyRefusal.unreadableReferences(kind: NovelForgeKind.chapterPlan.rawValue, count: 1)
    try await planWorld.refuses(#"{"op":"milestone.remove","milestoneKey":"rise"}"#, with: ApplyError.refused(planRefusal))
  }

  @Test func shouldRefuseAPromiseChapterItCannotWorkOutWhileADraftCannotBeRead() async throws {
    let world = try await StoryWorld.make()
    try await world.seed(ThreadRecord(novel: world.novel, thread: "oath", summary: "The oath."))
    try await unreadableHead(try world.draft(chapter: 6), in: world)
    try await world.refuses(#"{"op":"promise.create","kind":"thread","key":"oath","label":"L."}"#, with: .domain(.promiseExists(.thread("oath"))))
    let refusal = ApplyRefusal.unreadableReferences(kind: NovelForgeKind.draft.rawValue, count: 1)
    try await world.refuses(#"{"op":"promise.create","kind":"thread","key":"t","label":"L."}"#, with: ApplyError.refused(refusal))
    try await world.refuses(#"{"op":"promise.update","kind":"thread","key":"oath","status":"paid_off"}"#, with: ApplyError.refused(refusal))
    try await world.refuses(#"{"op":"promise.update","kind":"thread","key":"oath","lastAdvancedChapter":1}"#, with: ApplyError.refused(refusal))
    _ = try await world.apply(#"{"op":"promise.create","kind":"thread","key":"t","label":"L.","openedChapter":2}"#).get()
    _ = try await world.apply(#"{"op":"promise.update","kind":"thread","key":"oath","status":"open","label":"Oath."}"#).get()
    #expect(live(try await world.thread("t"))?.openedChapter == 2)
  }
}
