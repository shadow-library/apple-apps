import Foundation
import ShadowCore
import ShadowStore
import ShadowText

/// What the plan prompt is filled from for one chapter: the outline pack with the plans either side, the obligations and the open milestones, and what vetting reads afterwards.
// apps/novel-forge-server/src/modules/actions/chapter-plan.service.ts:73-139
struct ChapterPlanContext: Equatable, Sendable {
  let chapter: Int
  let pack: OutlinePack
  let catalog: String
  let obligations: [PlanObligation]
  let milestones: String
  let claims: PlanClaims
  let facts: [PlanFact]
  let milestoneRows: [PlanMilestone]
  let world: PlanWorld
  let characters: Set<JSString>

  func input(length: ChapterPlanLength, authorIntent: String?, chosenDirection: String?) -> ChapterPlanInput {
    ChapterPlanInput(
      catalog: catalog, obligations: renderObligations(obligations), milestones: milestones, chapter: chapter, isEnding: claims.isEnding, length: length,
      authorIntent: authorIntent, chosenDirection: chosenDirection)
  }
}

extension ChapterPlanContext {
  /// Threads and mysteries reach the obligations in key order: the urgency sort is intransitive, so replicas must agree on the order it starts from.
  // apps/novel-forge-server/src/modules/actions/chapter-plan.service.ts:73-139
  static func assemble(
    _ world: OutlineWorld, chapter: Int, budgetTokens: Int = OutlinePack.budget, readsIsolatedRaw: Bool = false, recalled: RetrievalResults? = nil
  ) throws(OutlineLoadError) -> ChapterPlanContext {
    let volumeKey = volumeKey(world, chapter: chapter)
    let pack = try OutlinePack.assemble(world, request(world, chapter: chapter, budgetTokens: budgetTokens, readsIsolatedRaw: readsIsolatedRaw), recalled: recalled)
    let surrounding = world.neighbours.map { "## Chapter \($0.chapter): \($0.title ?? "")\n\($0.body)" }.joined(separator: "\n\n")
    let catalog = [pack.rendered, surrounding.isEmpty ? "" : "## Surrounding chapters\n\(surrounding)"].filter { !$0.isEmpty }.joined(separator: "\n\n")

    let volume = volumeKey.flatMap { key in world.volumes.first { $0.volumeKey.jsEquals(key) } }
    let byKey = { (left: OutlinePromise, right: OutlinePromise) in JSText.codeUnitPrecedes(left.key, right.key) }
    let sources = ObligationSources(
      chapter: chapter, previousEnding: world.previousEnding, threads: world.threads.jsStableSorted(by: byKey).map(\.planPromise),
      mysteries: world.mysteries.jsStableSorted(by: byKey).map(\.planPromise),
      volume: volume.map { ObligationVolume(volumeKey: $0.volumeKey, title: $0.title, objective: $0.objective) },
      milestoneStates: Dictionary(jsEntries: world.milestones.map { (key: $0.milestoneKey, value: $0.state) }),
      volumeStates: Dictionary(jsEntries: world.volumes.map { (key: $0.volumeKey, value: $0.state) }))
    let claims = PlanClaims(chapter: chapter, volumeKey: volumeKey, isEnding: world.slot?.isEnding ?? false, claimedMilestones: [])
    let facts = world.facts.map(\.planFact)
    let rows = world.milestones.map(\.planMilestone)
    return ChapterPlanContext(
      chapter: chapter, pack: pack, catalog: catalog, obligations: selectObligations(sources),
      milestones: renderPlanMilestones(rows, facts: facts, plan: claims, world: world.planWorld), claims: claims, facts: facts, milestoneRows: rows, world: world.planWorld,
      characters: Set(world.characters.map { JSString($0) }))
  }

  // chapter-plan.service.ts:130: the pack of the chapter's own span, under the volume its plan names or the nearest one
  static func request(_ world: OutlineWorld, chapter: Int, budgetTokens: Int = OutlinePack.budget, readsIsolatedRaw: Bool = false) -> OutlineRequest {
    OutlineRequest(chapter: chapter, budgetTokens: budgetTokens, volume: .key(volumeKey(world, chapter: chapter)), readsIsolatedRaw: readsIsolatedRaw)
  }

  private static func volumeKey(_ world: OutlineWorld, chapter: Int) -> String? {
    world.slot?.volumeKey ?? nearestVolumeKey(world.planWorld.plans.map(\.claims), chapter: chapter)
  }
}

extension VaultStore {
  func outlineWorld(novel: UUID, chapter: Int) async throws(OutlineLoadError) -> OutlineWorld {
    let load: OutlineLoad
    do throws(StoreError) {
      load = try await read { transaction in try OutlineLoader.load(novel: novel, chapter: chapter, in: transaction) }
    } catch {
      throw .store(error)
    }
    guard load.unreadable.isEmpty else { throw .unreadable(parts: load.unreadable) }
    return load.world
  }

  /// With `retrieval`, the pack carries what it finds for the volume goal; without it the pack has no retrieved sections, as the reference's without a
  /// retrieval service.
  func outlinePack(novel: UUID, request: OutlineRequest, retrieval: OutlineRetrieval? = nil) async throws(OutlineLoadError) -> OutlinePack {
    let world = try await outlineWorld(novel: novel, chapter: request.chapter)
    let recalled = await recall(novel: novel, query: OutlinePack.retrievalQuery(world, request), from: retrieval)
    return try OutlinePack.assemble(world, request, recalled: recalled)
  }

  func chapterPlanContext(
    novel: UUID, chapter: Int, budgetTokens: Int = OutlinePack.budget, readsIsolatedRaw: Bool = false, retrieval: OutlineRetrieval? = nil
  ) async throws(OutlineLoadError) -> ChapterPlanContext {
    let world = try await outlineWorld(novel: novel, chapter: chapter)
    let request = ChapterPlanContext.request(world, chapter: chapter, budgetTokens: budgetTokens, readsIsolatedRaw: readsIsolatedRaw)
    let recalled = await recall(novel: novel, query: OutlinePack.retrievalQuery(world, request), from: retrieval)
    return try ChapterPlanContext.assemble(world, chapter: chapter, budgetTokens: budgetTokens, readsIsolatedRaw: readsIsolatedRaw, recalled: recalled)
  }

  private func recall(novel: UUID, query: String?, from retrieval: OutlineRetrieval?) async -> RetrievalResults? {
    guard let retrieval, let query else { return nil }
    return await retrieval.recall(novel: novel, query: query)
  }
}
