import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let appearance = item("appearance:mara", .appearance, ["category": "appearance", "entityKey": "mara"])

private func item(
  _ key: String, _ category: FinalizeCategory, _ proposed: [String: JSONValue], subject: String = "mara", dependents: [String]? = nil, auto: Bool = false
) -> StoredFinalizeItem {
  StoredFinalizeItem(
    key: key, position: 0, category: .known(category), triage: .known(.routine), basis: .known(.observed), subject: subject, claim: "Mara appears.", proposed: proposed,
    dependents: dependents, autoDecision: auto ? .known(.kept) : nil)
}

private enum ReadinessWorld {
  static func store(allowingFaults: Bool = false) async throws -> VaultStore {
    let store = try Projection.store(try Projection.reconciler(), allowingFaults: allowingFaults)
    try await write(store) { transaction in
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.secret(novel: novel, "tide", revealChapter: 3, in: &transaction)
      for chapter in 1...3 { try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(contract()), in: &transaction) }
    }
    return store
  }

  static func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
    _ = try await Projection.write(store) { transaction in try body(&transaction) }
  }

  @discardableResult
  static func draft(
    _ store: VaultStore, chapter: Int = 1, body: String = "The tide turns.", summary: String? = "It turns.", isolated: Bool = false,
    state: [String: JSONValue]? = nil
  ) async throws -> String {
    try await Projection.write(store) { transaction in
      let content = DraftContent(
        body: body, summary: summary, source: .known(.handEdited), isolated: isolated, upstream: try DraftUpstream.current(novel: novel, chapter: chapter, in: transaction),
        state: state)
      let record = try DraftRecord(novel: novel, chapter: chapter, content: content)
      if case .absent = try DraftRecord.read(record.ref, in: transaction) {
        _ = try record.create(in: &transaction)
      } else {
        _ = try DraftRecord.revise(record.ref, content, in: &transaction)
      }
      return try ChapterWrites.head(novel: novel, chapter: chapter, in: transaction) ?? ""
    }
  }

  static func approve(_ store: VaultStore, chapter: Int = 1) async throws {
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: chapter, in: &transaction) }
  }

  static func approvedDraft(_ store: VaultStore, body: String = "The tide turns.") async throws -> String {
    let head = try await draft(store, body: body)
    try await approve(store)
    return head
  }

  static func read(_ store: VaultStore, revision: String, body: String = "The tide turns.", items: [StoredFinalizeItem], seed: UInt64) async throws {
    let attempt = try ReviewWrites.attempt(seed)
    let job = try JobWorld.key(novel: novel, chapter: 1, kind: .finalizeReview).ref.key
    let record = try FinalizeReviewRecord(
      attempt: attempt, job: job, novel: novel, chapter: 1, draftRevision: revision, sourceHash: hashReviewedBody(body), planHash: nil, isolated: false, items: items)
    try await write(store) { transaction in _ = try record.append(in: &transaction) }
  }

  static func answer(_ store: VaultStore, revision: String, item: StoredFinalizeItem, _ decision: FinalizeDecision) async throws {
    let digest = ProposedChange(json: .object(item.proposed))?.digest ?? "unreadable"
    let answer = StoredFinalizeAnswer(decision: .known(decision), proposalDigest: digest)
    try await write(store) { transaction in
      _ = try FinalizeDecisionRecord(novel: novel, chapter: 1, draftRevision: revision, item: item.key, answer: answer).create(in: &transaction)
    }
  }

  static func readiness(_ store: VaultStore, chapter: Int = 1) async throws -> FinalizeReadiness {
    try await store.load(FinalizeReadiness.self, FinalizeReadinessQuery(novel: novel, chapter: chapter))
  }

  static func blockers(_ store: VaultStore, chapter: Int = 1) async throws -> [FinalizeBlocker] {
    try #require(try await readiness(store, chapter: chapter).blockers.value)
  }

  static func codes(_ store: VaultStore, chapter: Int = 1) async throws -> [String] {
    try await blockers(store, chapter: chapter).map(\.code)
  }
}

@Suite("Finalize readiness read model", .timeLimit(.minutes(2)))
struct FinalizeReadinessTests {
  // generation.service.ts:635 reads the draft first (DRF_001) and finalize-refusals.ts:13 answers a final chapter with DRF_002 alone.
  @Test func shouldRefuseAChapterWithoutADraftAndAFinalOneAlone() async throws {
    let store = try await ReadinessWorld.store()
    #expect(try await ReadinessWorld.blockers(store, chapter: 2) == [.draftNotFound])
    #expect(try await ReadinessWorld.blockers(store, chapter: 9) == [.draftNotFound])
    _ = try await ReadinessWorld.approvedDraft(store)
    try await ReadinessWorld.write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await ReadinessWorld.blockers(store) == [.draftFinal(chapter: 1)])
    #expect(try await ReadinessWorld.codes(store) == ["DRF_002"])
  }

  // finalize-refusals.ts:36, 41: an unapproved draft with no summary.
  @Test func shouldListAnUnapprovedDraftWithoutASummary() async throws {
    let store = try await ReadinessWorld.store()
    try await ReadinessWorld.draft(store, summary: "  ")
    let readiness = try await ReadinessWorld.readiness(store)
    #expect(readiness.blockers == .available([.notApproved(chapter: 1), .summaryMissing(chapter: 1)]))
    #expect(try await ReadinessWorld.codes(store) == ["DRF_004", "CHP_010"])
    #expect(!readiness.isReady)
  }

  // Decision 2: with no read of the approved head, finalize refuses as still preparing (FRV_002), whatever other revisions were read.
  @Test func shouldWaitForAReadOfTheApprovedHead() async throws {
    let store = try await ReadinessWorld.store()
    let first = try await ReadinessWorld.draft(store)
    try await ReadinessWorld.read(store, revision: first, items: [], seed: 1)
    _ = try await ReadinessWorld.approvedDraft(store, body: "The tide turns twice.")
    #expect(try await ReadinessWorld.blockers(store) == [.reviewPreparing])
    #expect(try await ReadinessWorld.codes(store) == ["FRV_002"])
  }

  @Test func shouldBeReadyOnceEveryItemOfTheHeadsReadIsAnswered() async throws {
    let store = try await ReadinessWorld.store()
    let head = try await ReadinessWorld.approvedDraft(store)
    let kept = item("appearance:oren", .appearance, ["category": "appearance", "entityKey": "oren"], auto: true)
    try await ReadinessWorld.read(store, revision: head, items: [appearance, kept], seed: 2)
    #expect(try await ReadinessWorld.blockers(store) == [.unanswered(count: 1)])
    #expect(try await ReadinessWorld.codes(store) == ["FRV_005"])
    try await ReadinessWorld.answer(store, revision: head, item: appearance, .kept)
    let readiness = try await ReadinessWorld.readiness(store)
    #expect(readiness.blockers == .available([]))
    #expect(readiness.isReady)
  }

  // finalize-review-gate.ts:25, 51: a read of other text than the head's no longer applies.
  @Test func shouldRefuseAReadWhoseSourceIsNotTheHeadsText() async throws {
    let store = try await ReadinessWorld.store()
    let head = try await ReadinessWorld.approvedDraft(store)
    try await ReadinessWorld.read(store, revision: head, body: "Other text.", items: [], seed: 3)
    #expect(try await ReadinessWorld.blockers(store) == [.proseChanged])
    #expect(try await ReadinessWorld.codes(store) == ["FRV_004"])
  }

  // finalize-review-gate.ts:32-45: a kept milestone left unreached strands the reveals that need it.
  @Test func shouldRefuseAStrandedReveal() async throws {
    let store = try await ReadinessWorld.store()
    let head = try await ReadinessWorld.approvedDraft(store)
    let milestone = item("milestone:rise", .milestone, ["category": "milestone", "milestoneKey": "rise", "reached": false], subject: "rise", dependents: ["heir"])
    try await ReadinessWorld.read(store, revision: head, items: [milestone], seed: 4)
    try await ReadinessWorld.answer(store, revision: head, item: milestone, .kept)
    #expect(try await ReadinessWorld.blockers(store) == [.strandedReveal(milestone: "rise", facts: ["heir"])])
    #expect(try await ReadinessWorld.codes(store) == ["FRV_006"])
  }

  @Test func shouldCountAnItemThisVersionCannotReadAsOpenUntilItIsAnswered() async throws {
    let store = try await ReadinessWorld.store()
    let head = try await ReadinessWorld.approvedDraft(store)
    var unknown = appearance
    unknown.key = "portrait:mara"
    unknown.category = StoredEnum(rawValue: "portrait")
    try await ReadinessWorld.read(store, revision: head, items: [unknown], seed: 5)
    #expect(try await ReadinessWorld.blockers(store) == [.unanswered(count: 1)])
    try await ReadinessWorld.answer(store, revision: head, item: unknown, .skipped)
    #expect(try await ReadinessWorld.blockers(store) == [])
  }

  // finalize-review.service.ts:523-554 at read time: a skip on an earlier revision's read carries to the head's.
  @Test func shouldCarryASkipFromAnEarlierRevisionsRead() async throws {
    let store = try await ReadinessWorld.store()
    let first = try await ReadinessWorld.draft(store)
    try await ReadinessWorld.read(store, revision: first, items: [appearance], seed: 6)
    try await ReadinessWorld.answer(store, revision: first, item: appearance, .skipped)
    let head = try await ReadinessWorld.approvedDraft(store, body: "The tide turns twice.")
    try await ReadinessWorld.read(store, revision: head, body: "The tide turns twice.", items: [appearance], seed: 7)
    #expect(try await ReadinessWorld.blockers(store) == [])
  }

  // finalize-refusals.ts:38: an open blocking finding on the latest judge review of the head, which also holds the draft as a contradiction.
  @Test func shouldListAnOpenBlockingFinding() async throws {
    let store = try await ReadinessWorld.store()
    try await ReadinessWorld.draft(store)
    try await ReadinessWorld.write(store) { transaction in
      try ReviewWrites.judge(novel: novel, chapter: 1, findings: [ReviewWrites.finding("f1")], in: &transaction)
    }
    try await ReadinessWorld.approve(store)
    let blockers = try await ReadinessWorld.blockers(store)
    #expect(blockers == [.notApproved(chapter: 1), .openBlockingFindings(chapter: 1, count: 1)])
    #expect(blockers.map(\.code) == ["DRF_004", "FIN_004"])
    #expect(blockers[1].message.hasPrefix("Chapter 1 has a blocking review finding still open"))
  }

  @Test func shouldListAStaleDraftAndAnEarlierChapterThatIsNotFinal() async throws {
    let store = try await ReadinessWorld.store()
    try await ReadinessWorld.draft(store)
    try await ReadinessWorld.draft(store, chapter: 2)
    try await ReadinessWorld.draft(store, body: "The tide turns back.")
    let blockers = try await ReadinessWorld.blockers(store, chapter: 2)
    #expect(blockers.map(\.code) == ["DRF_004", "DRF_007", "FIN_001"])
    guard case .stale(2, .ancestorDraft(chapter: 1, _)) = blockers[1] else {
      Issue.record("not stale on chapter 1: \(blockers)")
      return
    }
  }

  // common/finalize-gate.ts:21-24: an isolated chapter needs its summary and a continuation state.
  @Test func shouldRefuseAnIsolatedChapterWithoutContinuationState() async throws {
    let store = try await ReadinessWorld.store()
    try await ReadinessWorld.draft(store, isolated: true)
    #expect(try await ReadinessWorld.codes(store) == ["DRF_004", "CHP_005"])
    try await ReadinessWorld.draft(store, body: "The tide turns twice.", isolated: true, state: ["thread": "open"])
    #expect(try await ReadinessWorld.codes(store) == ["DRF_004"])
  }

  // plan-state.ts:57-62: a plan that teaches a fact before it is revealed.
  @Test func shouldListAPlanThatBreaksTheRevealRule() async throws {
    let store = try await ReadinessWorld.store()
    try await ReadinessWorld.write(store) { transaction in
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "tide")])), in: &transaction)
    }
    try await ReadinessWorld.draft(store)
    let blockers = try await ReadinessWorld.blockers(store)
    #expect(blockers.map(\.code) == ["DRF_004", "DRF_007", "PLN_004"])
  }

  @Test func shouldNotBeReadyWhileAGenerateJobForTheChapterIsOpen() async throws {
    let store = try await ReadinessWorld.store()
    let head = try await ReadinessWorld.approvedDraft(store)
    try await ReadinessWorld.read(store, revision: head, items: [], seed: 8)
    #expect(try await ReadinessWorld.readiness(store).isReady)
    try await ReadinessWorld.write(store) { transaction in try ReviewWrites.requestGeneration(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await ReadinessWorld.blockers(store) == [.notApproved(chapter: 1)])
  }

  @Test func shouldBeUnavailableAndNotReadyWhileTheLifecycleIsFaulted() async throws {
    let store = try await ReadinessWorld.store(allowingFaults: true)
    let head = try await ReadinessWorld.approvedDraft(store)
    try await ReadinessWorld.read(store, revision: head, items: [], seed: 9)
    try await ReadWorld.insertFault(ChapterLifecycleEntry.databaseTableName, key: ProjectionFaults.key(novel), in: store)
    let readiness = try await ReadinessWorld.readiness(store)
    #expect(readiness.blockers.isUnavailable && !readiness.isReady)
    #expect(readiness.faults.map(\.derivation) == [ChapterLifecycleEntry.databaseTableName])
  }
}
