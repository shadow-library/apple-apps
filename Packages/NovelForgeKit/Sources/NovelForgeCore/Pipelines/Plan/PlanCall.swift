import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText

enum PlanPipelineError: ShadowError {
  case novelUnavailable
  case contentModeUnknown(String)
  case outline(OutlineLoadError)
  case route(ChapterCallError)
  case call(JobStepCallError)
  case disclosure(DisclosureError)
  case refsUnreadable([String])
  case planUnreadable
  case existingPlanUnreadable
  case checkpointUnreadable
  case changeSet(ChangeSetError)
  case staging(ProposalStagingError)
  case store(StoreError)

  var code: String {
    switch self {
    case .novelUnavailable: "plan.novel_unavailable"
    case .contentModeUnknown: "plan.content_mode_unknown"
    case .outline(let error): error.code
    case .route(let error): error.code
    case .call(let error): error.code
    case .disclosure(let error): error.code
    case .refsUnreadable: "plan.refs_unreadable"
    case .planUnreadable: "plan.plan_unreadable"
    case .existingPlanUnreadable: "plan.existing_plan_unreadable"
    case .checkpointUnreadable: "plan.checkpoint_unreadable"
    case .changeSet(let error): error.code
    case .staging(let error): error.code
    case .store(let error): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .novelUnavailable: "The novel cannot be read on this device, so its chapter cannot be planned."
    case .contentModeUnknown(let raw): "The novel's content mode \(raw) is not one this version knows, so the plan is not routed."
    case .outline(let error): error.errorDescription
    case .route(let error): error.errorDescription
    case .call(let error): error.errorDescription
    case .disclosure(let error): error.errorDescription
    case .refsUnreadable(let parts): "The story's \(parts.joined(separator: ", ")) cannot be read on this device, so the plan's context cannot be checked."
    case .planUnreadable: "The planner's reply is not a chapter plan."
    case .existingPlanUnreadable: "The chapter's plan cannot be read on this device, so a new plan could not say what it replaces."
    case .checkpointUnreadable: "The plan this attempt made cannot be read back."
    case .changeSet(let error): error.errorDescription
    case .staging(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }
}

private enum ExistingPlanReading {
  case none
  case plan(ExistingPlan)
  case unreadable
}

/// What the plan call reads beside the outline pack, in one read; an empty plan reads no refs.
private struct PlanSubject: Sendable {
  let novel: NovelRecord
  let mode: ContentMode
  let existing: ExistingPlan?
  let refs: WriterPackWorld?
}

/// The plugin policy's writer class (plugin-policy.service.ts:69-71, 189): with no plugins natively it is the novel's own mode, so an unrestricted novel's
/// planner reads isolated chapters raw (context-assembler.service.ts:644) and is routed unrestricted (model-router.service.ts:375-378).
struct PlanPolicy: Sendable, Equatable {
  let permissive: Bool

  init(_ mode: ContentMode) {
    permissive = mode == .unrestricted
  }
}

enum PlanCall {
  static let logger = Logger(category: "plan.call")

  /// apps/novel-forge-server/src/modules/actions/chapter-plan.service.ts:66-125 and plan-job.service.ts:160-162: re-checks that the chapter is still next,
  /// assembles the outline pack (screened for the hard line when the planner reads isolated chapters raw), makes one structured call through the engine and
  /// keeps the plan within the reveal rule.
  static func plan(_ input: PlanJobInput, in context: JobStepContext) async throws -> PlanCardOp {
    let (store, novel, chapter) = (context.store, context.target.novel, context.target.chapter)
    let now = LeaseInstant(date: context.services.now(), source: .device)
    let subject = try await read(store) { transaction in try subject(novel: novel, chapter: chapter, empty: input.empty, at: now, in: transaction) }
    guard let refs = subject.refs else {
      let obligations = try await planContext(store, novel: novel, chapter: chapter, policy: PlanPolicy(.standard), retrieval: nil).obligations
      return emptyPlanOp(PlanOpInput(chapter: chapter, steer: input.steer, rationale: planRationale(obligations)))
    }
    let policy = PlanPolicy(subject.mode)
    let plan = try await planContext(store, novel: novel, chapter: chapter, policy: policy, retrieval: .index(context.services.retrieval))
    let route: ChapterCallRoute
    do {
      // A plan takes the novel's mode when it is made (chapter-route.ts:34), so the planner is routed by it, as routeModel routes the outline call.
      route = try ChapterCallRouter.route(
        ChapterCallSource(novel: novel, chapter: chapter, role: .extraction, plan: ChapterPlanContent(body: "", contentMode: .known(subject.mode)), isolated: false),
        unrestrictedAvailable: context.unrestrictedAvailable)
    } catch {
      throw PlanPipelineError.route(error)
    }
    let length = ChapterPlanLength(ResolvedWordTarget.resolve(subject.novel.wordTarget))
    let prompt = chapterPlanRequest(plan.input(length: length, authorIntent: input.intent, chosenDirection: input.direction))
    let (claims, facts, world) = (plan.claims, plan.facts, plan.world)
    let result: StructuredResult
    do {
      result = try await context.call(
        route, pace: subject.novel.costTier.known?.pace ?? .steady, screening: screened(plan, length: length, input: input),
        sections: plan.pack.sections.map { ContextSection(key: $0.key, rendered: $0.rendered, sourceRefs: $0.sourceRefs) },
        request: { call in prompt.modelRequest(model: call.route.model, maxOutputTokens: call.route.maxOutputTokens, effort: call.route.effort) },
        name: chapterPlanSchemaName, schema: JSONValue(schema: chapterPlanCallSchema),
        review: chapterPlanReview { output in (try? planAdvice(output, plan: claims, facts: facts, world: world)) ?? [] })
    } catch {
      throw PlanPipelineError.call(error)
    }
    guard let json = try? OrderedJSON(parsing: String(decoding: result.json, as: UTF8.self)), let output = PlannedChapter(json: json) else {
      throw PlanPipelineError.planUnreadable
    }
    let requiredContext = json.objectValue?["requiredContext"]?.arrayValue?.compactMap(\.stringValue) ?? []
    return try card(output, requiredContext: requiredContext, plan: plan, existing: subject.existing, refs: refs, input: input)
  }

  // chapter-plan.service.ts:116-124
  private static func card(
    _ output: PlannedChapter, requiredContext: [String], plan: ChapterPlanContext, existing: ExistingPlan?, refs: WriterPackWorld, input: PlanJobInput
  ) throws -> PlanCardOp {
    var vetted: VettedPlan
    do {
      vetted = try vetPlan(output, plan: plan.claims, facts: plan.facts, world: plan.world)
    } catch {
      throw PlanPipelineError.disclosure(error)
    }
    if !vetted.droppedClaims.isEmpty || !vetted.sanitised.isEmpty {
      logger.notice(
        "Kept the plan within the reveal rule chapter=\(plan.chapter, privacy: .public) droppedClaims=\(vetted.droppedClaims.count, privacy: .public) sanitised=\(vetted.sanitised.count, privacy: .public)"
      )
    }
    vetted.plan = resolveScenePovs(vetted.plan, characterKeys: plan.characters)
    let (kept, dropped) = try outlinedRefs(requiredContext, chapter: plan.chapter, in: refs)
    if !dropped.isEmpty { logger.notice("Dropped context refs from the plan chapter=\(plan.chapter, privacy: .public) dropped=\(dropped.count, privacy: .public)") }
    let rationale = planRationale(plan.obligations, moves: vetted.moves)
    return chapterPlanOp(PlanOpInput(chapter: plan.chapter, steer: input.steer, rationale: rationale), existing: existing, vetted: vetted, contextRefs: kept)
  }

  /// context-ref-resolver.ts:195-202: every `fact:` ref is dropped, since the planner reads hidden facts in full, and so is a ref the planner's resolver cannot
  /// resolve; a planner-only page never resolves.
  private static func outlinedRefs(_ refs: [String], chapter: Int, in world: WriterPackWorld) throws -> (kept: [String], dropped: [String]) {
    let candidates = refs.filter { !$0.jsStartsWith("fact:") }
    var disclosure = WriterDisclosurePolicy.planner
    let unresolved: Set<JSString>
    do {
      unresolved = Set(try world.resolveRefs(candidates, chapter: chapter, disclosure: &disclosure).unresolved.map { JSString($0) })
    } catch {
      throw PlanPipelineError.disclosure(error)
    }
    let kept = candidates.filter { !unresolved.contains(JSString($0)) }
    let keptSet = Set(kept.map { JSString($0) })
    return (kept, refs.filter { !keptSet.contains(JSString($0)) })
  }

  /// The prompt's inputs under the reference's names, so an unrestricted call screens each at its scope (hard-line.ts:234).
  // chapter-plan.service.ts:103-112
  private static func screened(_ plan: ChapterPlanContext, length: ChapterPlanLength, input: PlanJobInput) -> OrderedJSONObject {
    let filled = plan.input(length: length, authorIntent: input.intent, chosenDirection: input.direction)
    let texts: [(String, String)] = [
      ("catalog", filled.catalog), ("obligations", filled.obligations), ("milestones", filled.milestones), ("chapterNumber", String(filled.chapter)),
      ("endingNote", filled.isEnding ? chapterPlanEnding : chapterPlanNotEnding), ("wordTargetMin", length.min), ("wordTargetMax", length.max),
      ("wordTargetAim", length.aim), ("minScenes", length.minScenes), ("authorIntent", input.intent ?? chapterPlanNone),
      ("chosenDirection", input.direction ?? chapterPlanNone),
    ]
    return OrderedJSONObject(texts.map { (key: $0.0, value: OrderedJSON.string($0.1)) })
  }

  private static func planContext(
    _ store: VaultStore, novel: UUID, chapter: Int, policy: PlanPolicy, retrieval: OutlineRetrieval?
  ) async throws -> ChapterPlanContext {
    do {
      return try await store.chapterPlanContext(novel: novel, chapter: chapter, readsIsolatedRaw: policy.permissive, retrieval: retrieval)
    } catch {
      throw PlanPipelineError.outline(error)
    }
  }

  /// A plan head this version cannot read counts as a plan, as `PlanRequests.planExists` does: an empty plan is refused over it (PLN_007), and a full plan
  /// could not say what it replaces.
  private static func subject(novel: UUID, chapter: Int, empty: Bool, at now: LeaseInstant, in transaction: ReadTransaction) throws -> PlanSubject {
    let next = try PlanRequests.nextWritableChapter(novel: novel, in: transaction)
    guard next == chapter else { throw ChapterPlanError.notNextChapter(chapter: chapter, next: next) }
    try PlanRequests.requireNoGeneration(novel: novel, chapter: chapter, at: now, in: transaction)
    guard case .readable(let entry) = try NovelRecord.read(id: novel, in: transaction), !entry.isRemoved else { throw PlanPipelineError.novelUnavailable }
    guard let mode = entry.record.contentMode.known else { throw PlanPipelineError.contentModeUnknown(entry.record.contentMode.rawValue) }
    let existing: ExistingPlan?
    switch try existingPlan(novel: novel, chapter: chapter, in: transaction) {
    case .none: existing = nil
    case .plan(let plan): existing = plan
    case .unreadable: throw empty ? ChapterPlanError.alreadyPlanned(chapter: chapter) : PlanPipelineError.existingPlanUnreadable
    }
    if empty {
      guard existing == nil else { throw ChapterPlanError.alreadyPlanned(chapter: chapter) }
      return PlanSubject(novel: entry.record, mode: mode, existing: nil, refs: nil)
    }
    let load = try WriterPackLoader.load(novel: novel, chapter: chapter, in: transaction)
    guard load.unreadable.isEmpty else { throw PlanPipelineError.refsUnreadable(load.unreadable.map(\.rawValue)) }
    return PlanSubject(novel: entry.record, mode: mode, existing: existing, refs: load.world)
  }

  // chapter-plan.service.ts:71, the plan the card replaces
  private static func existingPlan(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> ExistingPlanReading {
    guard let ref = try? ChapterPlanRecord.ref(novel: novel, chapter: chapter) else { return .none }
    switch try ChapterPlanRecord.readHead(ref, in: transaction) {
    case .absent: return .none
    case .unreadable: return .unreadable
    case .readable(let entry):
      guard !entry.isRemoved else { return .none }
      let content = entry.record.content
      return .plan(ExistingPlan(hasKnowledgeContract: !content.contract.pov.isEmpty || !content.contract.learns.isEmpty, direction: content.direction))
    }
  }

  private static func read<T: Sendable>(_ store: VaultStore, _ body: @Sendable (ReadTransaction) throws -> T) async throws -> T {
    do {
      return try await store.read(body)
    } catch {
      throw unwrapped(error)
    }
  }

  static func unwrapped(_ error: any Error) -> any Error {
    guard case StoreError.aborted(let inner) = error else { return error }
    return unwrapped(inner)
  }
}
