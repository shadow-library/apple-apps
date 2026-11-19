import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// apps/novel-forge-server/tests/finalize-review/finalize-review.service.spec.ts:12-28: the prose, the extraction its continuity call returns, and the one with
/// nothing to ask.
enum FinalizeReviewScript {
  static let prose = "Mira climbs the tower and the lamp burns cold."

  static let extraction: JSONValue = [
    "appeared": ["mira"], "newEntities": [], "threads": [["threadKey": "lamp_debt", "status": "closed", "summary": "Mira repays the keeper"]], "mysteries": [],
    "timeline": [], "relationships": [], "power": [], "characterStates": [["entityKey": "mira", "location": "the tower", "evidence": "Mira climbs the tower"]],
    "knowledgeChanges": [], "chapterSummary": "Mira climbs.", "milestones": [],
  ]

  static var confident: JSONValue { replacing(extraction, "threads", with: []) }

  static func replacing(_ value: JSONValue, _ member: String, with replacement: JSONValue) -> JSONValue {
    guard var members = value.objectValue else { return value }
    members[member] = replacement
    return .object(members)
  }

  static func reply(_ extraction: JSONValue = extraction) -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(extraction), as: UTF8.self))
  }
}

/// Records each chapter the pipeline finalizes on approval, or refuses as `refusal` says.
final class FinalizeRecorder: Sendable {
  private let state = Mutex<(finalized: [Int], refusal: DomainError?)>(([], nil))

  var finalized: [Int] { state.withLock { $0.finalized } }

  func refuse(with error: DomainError) {
    state.withLock { $0.refusal = error }
  }

  var seam: FinalizeReviewPipeline.Finalize {
    { _, chapter, _ throws(DomainError) in
      let refusal = self.state.withLock { state -> DomainError? in
        if state.refusal == nil { state.finalized.append(chapter) }
        return state.refusal
      }
      if let refusal { throw refusal }
    }
  }
}

/// A novel whose chapter 1 is drafted with `FinalizeReviewScript.prose` and approved, its finalize review run by a real engine against a scripted model.
struct FinalizeReviewWorld {
  let base: JobEngineWorld
  let recorder = FinalizeRecorder()

  var store: VaultStore { base.store }
  var novel: UUID { base.novel }
  var provider: ScriptedModelProvider { base.provider }

  init(replies: [[ScriptedModelProvider.Step]] = [FinalizeReviewScript.reply()], store: VaultStore? = nil) async throws {
    base = try await JobEngineWorld(store: store, provider: ScriptedModelProvider(calls: replies))
    let novel = novel
    try await Projection.write(base.store) { transaction in
      try ChapterWrites.entity(novel: novel, "mira", in: &transaction)
      var plan = PlanEdit(body: "Mira climbs the tower.")
      plan.knowledge = .set(PlanKnowledge(pov: ["mira"], learns: []))
      _ = try ChapterPlans.write(novel: novel, chapter: 1, plan, in: &transaction)
    }
  }

  func engine(
    finalizing finalize: FinalizeReviewPipeline.Finalize? = nil, faults: AttemptRunner.Faults = .none, unrestrictedAvailable: Bool = false
  ) throws -> JobEngine {
    let world = base
    let pipeline = FinalizeReviewPipeline.pipeline(finalizing: finalize ?? recorder.seam)
    return try JobEngine(
      store: store, router: { world.router($0) }, consent: CompactionWorld.consent, clock: LeaseClock(trusted: nil, device: base.clock.function),
      runner: base.runner(faults), catalog: { kind in kind == .finalizeReview ? .ready(pipeline) : PipelineCatalog.definition(for: kind) },
      packs: base.packs.builder(store), timing: JobEngine.Timing { _ in try await world.rereads.sleep() }, unrestrictedAvailable: unrestrictedAvailable)
  }

  @discardableResult
  func draft(_ body: String = FinalizeReviewScript.prose, summary: String = "Mira climbs.", isolated: Bool = false) async throws -> String {
    let novel = novel
    return try await Projection.write(store) { transaction in
      let upstream = try DraftUpstream.current(novel: novel, chapter: 1, in: transaction)
      let content = DraftContent(
        body: body, summary: summary, source: .known(.handEdited), generator: .known(isolated ? .unrestricted : .standard), isolated: isolated, upstream: upstream)
      let record = try DraftRecord(novel: novel, chapter: 1, content: content)
      if try DraftRecord.read(record.ref, in: transaction) == .absent {
        _ = try record.create(in: &transaction)
      } else {
        _ = try DraftRecord.revise(record.ref, content, in: &transaction)
      }
      return try ChapterWrites.head(novel: novel, chapter: 1, in: transaction) ?? ""
    }
  }

  func head() async throws -> String {
    let novel = novel
    return try #require(try await store.write { transaction in try ChapterWrites.head(novel: novel, chapter: 1, in: transaction) })
  }

  /// Approves the head and returns the finalize review job the approval requested.
  @discardableResult
  func approve() async throws -> EntityRef {
    let head = try await head()
    try await store.approveChapter(novel: novel, chapter: 1, revision: head)
    return try #require(try await store.finalizeReviewJob(novel: novel, chapter: 1))
  }

  func run(_ engine: JobEngine, _ job: EntityRef) async throws -> AttemptResult {
    try await engine.run(job: job).result
  }

  /// Drafts, approves and runs the review to its end.
  @discardableResult
  func prepared(on engine: JobEngine, autoKeep: [FinalizeCategory]? = nil, isolated: Bool = false) async throws -> EntityRef {
    if let autoKeep { try await store.setFinalizeAutoKeep(novel: novel, categories: autoKeep) }
    try await draft(isolated: isolated)
    let job = try await approve()
    #expect(try await run(engine, job) == .settled(.succeeded))
    return job
  }

  func reviews() async throws -> [AppendedEntry<FinalizeReviewRecord>] {
    let novel = novel
    return try await store.read { transaction in try FinalizeReviewRecord.listing(novel: novel, chapter: 1, in: transaction).entries }
  }

  /// The head's review in force as the author's answers leave it.
  func inForce() async throws -> FinalizeReviewChain.Resolved {
    let novel = novel
    return try #require(
      try await store.writeDomain { transaction throws(DomainError) in
        guard case .live(let head) = try transaction.draft(novel: novel, chapter: 1) else { return nil }
        return try FinalizeReviewChain.inForce(novel: novel, chapter: 1, head: head.revision, in: transaction)
      })
  }

  /// What finalize would answer now, read as the commit's readiness reads it.
  func readiness() async throws -> Derived<[FinalizeBlocker]> {
    let novel = novel
    return try await store.read { transaction in try FinalizeReadiness.load(FinalizeReadinessQuery(novel: novel, chapter: 1), in: transaction).blockers }
  }

  func items(_ triage: FinalizeTriage) async throws -> [FinalizeReviewItem] {
    try await inForce().resolved.filter { $0.triage == triage }
  }

  func open() async throws -> (consequential: Int, routine: Int) {
    let items = try await inForce().resolved.filter { $0.decision == nil }
    return (items.filter { $0.triage == .consequential }.count, items.filter { $0.triage == .routine }.count)
  }

  func expectRefusal(_ code: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws(FinalizeAnswerError) -> Void) async {
    do throws(FinalizeAnswerError) {
      try await body()
      Issue.record("expected \(code)", sourceLocation: sourceLocation)
    } catch {
      #expect(error.code == code, "got \(error.code)", sourceLocation: sourceLocation)
    }
  }
}
