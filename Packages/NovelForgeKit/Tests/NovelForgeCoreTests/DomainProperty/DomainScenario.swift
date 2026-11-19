import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

/// Three devices sharing the novel of `DomainUniverse.setUp`, driven one domain call at a time, for the concurrency cases the random property rarely hits.
struct DomainScenario {
  let replicas: CausalReplicas
  let reconciler: NovelForgeReconciler
  let novel: UUID

  static func make(seed: UInt64, order: CausalReplicaOrder = .causal) async throws -> DomainScenario {
    let reconciler = try Projection.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, order: order, reconciler: { _ in reconciler }, seed: seed))
    var generator = SeededGenerator(seed: seed)
    let universe = DomainUniverse(&generator)
    try await universe.setUp(on: replicas)
    return DomainScenario(replicas: replicas, reconciler: reconciler, novel: universe.primary)
  }

  func store(_ index: Int) async -> VaultStore { await replicas.store(index) }

  /// One write on device `index`, a little later on its clock than its last.
  @discardableResult
  func on<T: Sendable>(_ index: Int, _ body: @escaping @Sendable (inout WriteTransaction, UUID) throws -> T) async throws -> T {
    await replicas.advanceClock(of: index, by: .seconds(700))
    let novel = novel
    return try await replicas.write(index) { transaction in try body(&transaction, novel) }
  }

  func plan(_ chapter: Int, on index: Int, learns: [KnowledgeReveal] = [], claims: [String]? = nil, ending: Bool? = nil, body: String = "The plan.") async throws {
    var edit = PlanEdit(body: body)
    edit.knowledge = .set(PlanKnowledge(pov: ["mara"], learns: learns))
    if let claims { edit.claimedMilestones = .set(claims) }
    if let ending { edit.isEnding = .set(ending) }
    let plan = edit
    try await on(index) { transaction, novel in try ChapterPlans.write(novel: novel, chapter: chapter, plan, in: &transaction) }
  }

  /// Saves against the head this device holds and leaves the editor, so a save that folded into this device's working copy is committed too.
  @discardableResult
  func draft(_ chapter: Int, on index: Int, _ body: String = "The tide turns.") async throws -> String {
    let base = try await head(chapter, on: index)
    await replicas.advanceClock(of: index, by: .seconds(700))
    let now = await store(index).wallClock()
    let novel = novel
    return try await replicas.write(index) { transaction in
      let outcome = try ChapterDrafts.save(novel: novel, chapter: chapter, DraftEdit(body: body, summary: "It turns."), base: base, at: now, in: &transaction)
      guard case .held = outcome else { return outcome.base }
      return try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: chapter, in: &transaction) ?? outcome.base
    }
  }

  func approve(_ chapter: Int, on index: Int, id: UUID) async throws {
    await replicas.advanceClock(of: index, by: .seconds(700))
    let revision = try await head(chapter, on: index) ?? ""
    try await store(index).approveChapter(novel: novel, chapter: chapter, revision: revision, id: id)
    try await replicas.collect(index)
  }

  func finalize(_ chapter: Int, on index: Int) async throws {
    try await on(index) { transaction, novel in _ = try FinalizeReviews.finalize(novel: novel, chapter: chapter, in: &transaction) }
  }

  func head(_ chapter: Int, on index: Int) async throws -> String? {
    let novel = novel
    return try await store(index).read { transaction in try DomainChapterOperations.head(novel: novel, chapter: chapter, in: transaction) }
  }

  func fetch<Output: FetchableRecord & Sendable>(_ request: QueryInterfaceRequest<Output>, on index: Int) async throws -> [Output] {
    try await Projection.fetch(request, in: await store(index))
  }

  /// Settles every device and holds each to the property's checks: a rebuild, no fault, equal tables, every invariant and every read model.
  func settle() async throws {
    try await replicas.settle()
    try await DomainProperty.expectSettled(reconciler, novels: [novel], in: replicas)
  }

  func expectRefused<T: Sendable>(
    _ expected: DomainError, on index: Int, sourceLocation: SourceLocation = #_sourceLocation, _ body: @escaping @Sendable (inout WriteTransaction, UUID) throws -> T
  ) async {
    do {
      try await on(index, body)
      Issue.record("expected \(expected.code), but the operation succeeded", sourceLocation: sourceLocation)
    } catch StoreError.aborted(let cause) {
      #expect(cause as? DomainError == expected, "got \(cause)", sourceLocation: sourceLocation)
    } catch {
      Issue.record("expected \(expected.code), got \(error)", sourceLocation: sourceLocation)
    }
  }
}
