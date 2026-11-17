import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let suggestion41 = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-000000000041")
private let suggestion42 = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-000000000042")

private func plan(_ chapter: Int, _ references: [String]) -> ImpactPlan {
  ImpactPlan(chapter: chapter, references: references)
}

// apps/novel-forge-server/tests/refinement/undo-impact.spec.ts:10-31, each plan's references as planReferences reads them
private let rows = ImpactRows(
  plans: [
    plan(3, ["volume:v1", "entity:mira"]), plan(4, ["entity:kael", "entity:kael", "entity:kael", "fact:crown"]),
    plan(5, ["milestone:court_falls", "doc:world/saltgate"]), plan(6, ["volume:v2", "entity:mira"]),
  ],
  drafts: [ImpactDraft(chapter: 3, isFinal: true), ImpactDraft(chapter: 4, isFinal: false), ImpactDraft(chapter: 5, isFinal: false)],
  knowledge: [
    ImpactKnowledge(fact: "crown", entity: "kael", learnedInChapter: 4, isCommitted: false),
    ImpactKnowledge(fact: "crown", entity: "mira", learnedInChapter: 2, isCommitted: true),
    ImpactKnowledge(fact: "tide", entity: "mira", learnedInChapter: 1, isCommitted: true),
  ],
  suggestions: [
    ImpactSuggestion(id: suggestion41, references: ["fact:tide", "entity:kael"]), ImpactSuggestion(id: suggestion42, references: ["chapter:7", "doc:world/saltgate"]),
  ])

private func created(_ refs: String...) -> UndoneChange { UndoneChange(created: refs, updated: []) }
private func updated(_ refs: String...) -> UndoneChange { UndoneChange(created: [], updated: refs) }

private func dependent(_ kind: UndoDependentKind, _ ref: String, _ chapter: Int?, _ because: String, final: Bool = false) -> UndoDependent {
  UndoDependent(kind: kind, ref: ref, chapter: chapter, because: because, final: final)
}

private let proposal41 = "proposal:\(suggestion41.uuidString.lowercased())"
private let proposal42 = "proposal:\(suggestion42.uuidString.lowercased())"

// undo-impact.spec.ts:42-156
private let cases: [(name: String, change: UndoneChange, dependents: [UndoDependent], finalUnaffected: Int)] = [
  (
    "a created character lists every plan that names it, their drafts, what it knows and the suggestions that name it", created("entity:kael"),
    [
      dependent(.plan, "chapter:4", 4, "entity:kael"), dependent(.draft, "draft:4", 4, "chapter:4"), dependent(.knowledge, "knowledge:kael/crown", 4, "entity:kael"),
      dependent(.suggestion, proposal41, nil, "entity:kael"),
    ], 0
  ),
  (
    "a created character lists finalized history too, marked final", created("entity:mira"),
    [
      dependent(.plan, "chapter:3", 3, "entity:mira", final: true), dependent(.plan, "chapter:6", 6, "entity:mira"),
      dependent(.draft, "draft:3", 3, "chapter:3", final: true), dependent(.knowledge, "knowledge:mira/tide", 1, "entity:mira", final: true),
      dependent(.knowledge, "knowledge:mira/crown", 2, "entity:mira", final: true),
    ], 0
  ),
  ("an updated character's field counts finalized plans and drafts, and leaves knowledge out", updated("entity:mira"), [dependent(.plan, "chapter:6", 6, "entity:mira")], 2),
  (
    "an updated secret keeps the knowledge rows about it", updated("fact:crown"),
    [
      dependent(.plan, "chapter:4", 4, "fact:crown"), dependent(.draft, "draft:4", 4, "chapter:4"),
      dependent(.knowledge, "knowledge:mira/crown", 2, "fact:crown", final: true), dependent(.knowledge, "knowledge:kael/crown", 4, "fact:crown"),
    ], 0
  ),
  (
    "a pending suggestion whose baseline holds an updated record is listed", updated("fact:tide"),
    [dependent(.knowledge, "knowledge:mira/tide", 1, "fact:tide", final: true), dependent(.suggestion, proposal41, nil, "fact:tide")], 0
  ),
  (
    "a Story Bible page lists the plans and suggestions that cite it in the stored ref format", created("doc:world/saltgate"),
    [
      dependent(.plan, "chapter:5", 5, "doc:world/saltgate"), dependent(.draft, "draft:5", 5, "chapter:5"),
      dependent(.suggestion, proposal42, nil, "doc:world/saltgate"),
    ], 0
  ),
  ("a volume lists the plans that serve it, undrafted ones included", created("volume:v2"), [dependent(.plan, "chapter:6", 6, "volume:v2")], 0),
  (
    "a milestone lists the plans that claim it", created("milestone:court_falls"),
    [dependent(.plan, "chapter:5", 5, "milestone:court_falls"), dependent(.draft, "draft:5", 5, "chapter:5")], 0
  ),
  ("an updated plan lists its own draft, not itself", updated("chapter:4"), [dependent(.draft, "draft:4", 4, "chapter:4")], 0),
  ("an updated draft lists the unfinalized drafts after it", updated("draft:2"), [dependent(.draft, "draft:4", 4, "draft:2"), dependent(.draft, "draft:5", 5, "draft:2")], 1),
  (
    "a dependent a created record reaches is listed even when an updated one only counted it", UndoneChange(created: ["volume:v1"], updated: ["entity:mira"]),
    [
      dependent(.plan, "chapter:3", 3, "volume:v1", final: true), dependent(.plan, "chapter:6", 6, "entity:mira"),
      dependent(.draft, "draft:3", 3, "chapter:3", final: true),
    ], 0
  ),
  ("a record nothing relies on lists nothing", created("entity:aldo", "premise"), [], 0),
]

@Suite("Undo impact", .timeLimit(.minutes(3)))
struct UndoImpactTests {
  // undo-impact.spec.ts:158-164
  @Test(arguments: cases.indices)
  func shouldFindWhatReliesOnTheUndoneRecords(_ index: Int) {
    let testCase = cases[index]
    let impact = UndoImpacts.impact(testCase.change, rows: rows)
    #expect(impact.dependents == testCase.dependents, "\(testCase.name)")
    #expect(impact.finalUnaffected == testCase.finalUnaffected, "\(testCase.name)")
  }

  // undo-impact.spec.ts:167-175
  @Test func shouldReadARecordWhoseInverseRemovesItAsCreatedAndEveryOtherAsUpdated() {
    let change = UndoImpacts.undoneChange(["entity:kael", "entity:mira", "premise"], removed: ["entity:kael"])
    #expect(change == UndoneChange(created: ["entity:kael"], updated: ["entity:mira", "premise"]))
  }

  // undo-impact.ts:80-92: a plan names its volume, POV and learners, the secrets it teaches, its claims and its cited pages
  @Test func shouldReadAPlansReferencesAsABriefUpdateCarryingItsFields() {
    var content = ChapterPlanContent(body: "Kael at the forge.")
    content.volume = "v1"
    content.pov = "mira"
    content.scenes = [PlanScene(BriefScene(summary: "At the forge", pov: "kael")), PlanScene(BriefScene(summary: "Empty", pov: ""))]
    content.contract = ChapterContract(pov: ["kael"], learns: [ContractLearn(KnowledgeReveal(entityKey: "kael", factKey: "crown"))], claimedMilestones: ["court_falls"])
    content.contextRefs = ["bible_doc:world/saltgate", "entity:aldo"]
    #expect(
      ImpactRowLoader.references(of: content) == [
        "volume:v1", "entity:mira", "entity:kael", "entity:kael", "entity:kael", "fact:crown", "milestone:court_falls", "doc:world/saltgate", "entity:aldo",
      ])
  }

  // undo-impact.spec.ts:190-200 over the store: an unapplied card refuses (RFN_007); an applied one lists what relies on the records it created
  @Test func shouldListAPendingSuggestionThatNamesARecordTheCardCreated() async throws {
    let (book, id) = try await RevertWorld.turn()
    #expect(await impactRefusal(book, id) == .notRevertible)
    try await book.applyTurn(id)
    let pending = try await book.stage(#"{"op":"fact.upsert","factKey":"kael-debt","body":"Kael owes the guild.","subjects":["kael"]}"#).proposal.id

    let change = try await book.impact(id, 0)
    #expect(change.dependents == [dependent(.suggestion, "proposal:\(pending.uuidString.lowercased())", nil, "entity:kael")])
    #expect(change.unreadable == 0)
    let whole = try await book.impact(id)
    #expect(whole.dependents.map(\.ref) == ["proposal:\(pending.uuidString.lowercased())"])

    try await book.undoChange(id, 1)
    #expect(await impactRefusal(book, id, 1) == .notToggleable(index: 1))
  }

  private func impactRefusal(_ book: ChapterBook, _ id: UUID, _ index: Int? = nil) async -> ProposalRevertError? {
    do {
      _ = try await book.impact(id, index)
      return nil
    } catch {
      return error as? ProposalRevertError
    }
  }
}
