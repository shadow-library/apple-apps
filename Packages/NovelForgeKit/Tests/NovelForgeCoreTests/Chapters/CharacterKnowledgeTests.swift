import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
  _ = try await Projection.write(store) { transaction in try body(&transaction) }
}

/// Plans 1 and 2 both teach `mara` the `heir`; plan 2 also teaches `tobin` the `tide`.
private func seeded() async throws -> VaultStore {
  let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations))
  try await write(store) { transaction in
    for key in ["heir", "tide"] { try PlanWorldWrites.secret(novel: novel, key, revealChapter: 1, in: &transaction) }
    for key in ["mara", "tobin"] { try ChapterWrites.entity(novel: novel, key, in: &transaction) }
    try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "heir")])), in: &transaction)
    try PlanWorldWrites.putPlan(novel: novel, chapter: 2, planContent(contract(learns: [Learn("mara", "heir"), Learn("tobin", "tide")])), in: &transaction)
  }
  return store
}

private func draftAndApprove(_ chapter: Int, in store: VaultStore) async throws {
  try await write(store) { transaction in
    try ChapterWrites.draft(novel: novel, chapter: chapter, in: &transaction)
    try ChapterWrites.approve(novel: novel, chapter: chapter, in: &transaction)
  }
}

private func knowledge(_ store: VaultStore) async throws -> Set<LedgerView> {
  try await ChapterTables.knowledge(novel, in: store)
}

@Suite("Character knowledge", .timeLimit(.minutes(2)))
struct CharacterKnowledgeTests {
  @Test func shouldLedgerEachPairAtItsEarliestApprovedChapterAndCommitItAtFinalize() async throws {
    let store = try await seeded()
    for chapter in 1...2 { try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: chapter, in: &transaction) } }
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 2, in: &transaction) }
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 2, .brief, .provisional), LedgerView("tide", "tobin", 2, .brief, .provisional)])
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 1, .brief, .provisional), LedgerView("tide", "tobin", 2, .brief, .provisional)])
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 1, .brief, .committed), LedgerView("tide", "tobin", 2, .brief, .provisional)])
    let rows = try await Projection.fetch(CharacterKnowledgeDerivation.request(for: novel), in: store)
    let head = try await store.write { transaction in try ChapterWrites.head(novel: novel, chapter: 1, in: transaction) }
    #expect(rows.first { $0.chapter == 1 }?.draftRevision == head)
  }

  @Test func shouldRevokeWhatAnApprovalLedgeredWhenItStopsHolding() async throws {
    let store = try await seeded()
    try await draftAndApprove(1, in: store)
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, body: "Rewritten.", in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
  }

  @Test func shouldKeepTheAuthorsManualRevealOverEveryPlan() async throws {
    let store = try await seeded()
    try await write(store) { transaction in try ChapterWrites.reveal(novel: novel, fact: "heir", entity: "mara", chapter: 5, in: &transaction) }
    try await draftAndApprove(1, in: store)
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 5, .manual, .committed)])
  }

  @Test func shouldHideARetractedPairFromEveryChapterThatTeachesIt() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.reveal(novel: novel, fact: "heir", entity: "mara", chapter: 5, in: &transaction)
      try ChapterWrites.retract(novel: novel, fact: "heir", entity: "mara", in: &transaction)
    }
    try await draftAndApprove(1, in: store)
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
    try await write(store) { transaction in try ChapterWrites.reveal(novel: novel, fact: "heir", entity: "mara", chapter: 4, in: &transaction) }
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 4, .manual, .committed)])
  }

  @Test func shouldHideThePairsOfARemovedSecretOrEntity() async throws {
    let store = try await seeded()
    try await draftAndApprove(2, in: store)
    try await write(store) { transaction in _ = try EntityRecord.remove(novel: novel, entity: "tobin", in: &transaction) }
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 2, .brief, .provisional)])
    try await write(store) { transaction in _ = try SecretRecord.remove(novel: novel, secret: "heir", in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
  }

  @Test func shouldSkipALearnTheRevealRuleRefusesAtTheFinalChapterAsTheWorldNowStands() async throws {
    let store = try await seeded()
    try await draftAndApprove(1, in: store)
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    var edit = SecretEdit()
    edit.revealChapter = .set(4)
    let changes = edit
    try await write(store) { transaction in _ = try SecretRecord.edit(SecretRecord.ref(novel: novel, secret: "heir"), changes.fields, in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
  }

  @Test func shouldNeverCommitALearnWhoseSecretWasCreatedAfterTheChapterWasFinalized() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "late")])), in: &transaction)
    }
    try await draftAndApprove(1, in: store)
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    try await write(store) { transaction in try PlanWorldWrites.secret(novel: novel, "late", revealChapter: 1, in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
  }

  @Test func shouldLedgerALearnerCreatedAfterTheApprovalOnlyOnceAnApprovalFollowsIt() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("elias", "heir")])), in: &transaction)
    }
    try await draftAndApprove(1, in: store)
    try await write(store) { transaction in try ChapterWrites.entity(novel: novel, "elias", in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await knowledge(store) == [LedgerView("heir", "elias", 1, .brief, .provisional)])
  }

  @Test func shouldNeverCommitALearnWhoseSecretWasCreatedBetweenTheApprovalAndFinalize() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "late")])), in: &transaction)
    }
    try await draftAndApprove(1, in: store)
    try await write(store) { transaction in try PlanWorldWrites.secret(novel: novel, "late", revealChapter: 1, in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
  }

  @Test func shouldCommitALearnWhoseSecretExistedWhenTheBoundApprovalWasMade() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try PlanWorldWrites.secret(novel: novel, "late", revealChapter: 1, in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "late")])), in: &transaction)
    }
    try await draftAndApprove(1, in: store)
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await knowledge(store) == [LedgerView("late", "mara", 1, .brief, .committed)])
    let finals = try await Projection.finals(in: store)
    #expect(finals.first?.approval != nil)
  }

  @Test func shouldCommitNothingFromACanonWhoseBoundApprovalHasNotArrivedAndOnlyWhatItLedgeredOnceItDoes() async throws {
    let writer = try await seeded()
    let reader = try Projection.store(try Projection.reconciler(chapterAreaDerivations))
    let approval = UUID()
    try await write(writer) { transaction in
      try PlanWorldWrites.secret(novel: novel, "early", revealChapter: 1, in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "early"), Learn("mara", "late")])), in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
    }
    try await write(writer) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, id: approval, in: &transaction) }
    try await write(writer) { transaction in try PlanWorldWrites.secret(novel: novel, "late", revealChapter: 1, in: &transaction) }
    try await write(writer) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await knowledge(writer) == [LedgerView("early", "mara", 1, .brief, .committed)])

    let lines = try await Projection.lines(of: writer)
    let isApproval = { (line: Data) in
      let text = String(decoding: line, as: UTF8.self)
      return text.contains(NovelForgeKind.approval.rawValue) && text.contains(ApprovalColumn.encode(approval))
    }
    #expect(lines.filter(isApproval).count == 1)
    try await Projection.apply(lines.filter { !isApproval($0) }, to: reader)
    #expect(try await Projection.finals(in: reader).first?.approval == approval)
    #expect(try await knowledge(reader).isEmpty)
    try await Projection.apply(lines.filter(isApproval), to: reader)
    #expect(try await knowledge(reader) == [LedgerView("early", "mara", 1, .brief, .committed)])
  }
}
