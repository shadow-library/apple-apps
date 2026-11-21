import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText

public enum StartedGeneration: Sendable {
  case running(JobRunHandle)
  /// Another device's attempt of the job holds a live lease.
  case elsewhere(EntityRef)
}

/// generation.service.ts:276-286 (`GenerateBody`): the author's guidance and the repair ladder's switch and cap.
public struct GenerationOptions: Sendable, Equatable {
  public var guidance: String
  public var autoFix: Bool
  public var maxFixes: Int

  public init(guidance: String = "", autoFix: Bool = true, maxFixes: Int = 3) {
    self.guidance = guidance
    self.autoFix = autoFix
    self.maxFixes = maxFixes
  }
}

public enum GenerationRequestError: ShadowError {
  case planMissing
  case planStale(chapter: Int)
  case chapterLocked
  case generationRunning
  case contradiction
  /// `blocker` is nil where the reference would interpolate `undefined`.
  case outOfOrder(chapter: Int, blocker: Int?)
  case externalChapter(chapter: Int, blocker: Int)
  case draftExists(Int)
  case teacherUnsettled(chapter: Int, teacher: Int)
  /// The chapter's route refused the call before anything was sent: AI_024 or an unknown content mode.
  case route(code: String, description: String?)
  case domain(DomainError)
  case engine(JobEngineError)

  public var code: String {
    switch self {
    case .planMissing: "BRF_001"
    case .planStale: "BRF_002"
    case .chapterLocked: "CHP_008"
    case .generationRunning: "DRF_010"
    case .contradiction: "DRF_003"
    case .outOfOrder: "DRF_011"
    case .externalChapter: "DRF_012"
    case .draftExists: "DRF_015"
    case .teacherUnsettled: "DRF_016"
    case .route(let code, _): code
    case .domain(let error): error.code
    case .engine(let error): error.code
    }
  }

  // apps/novel-forge-server/src/classes/app-error-code.ts:20-66
  public var errorDescription: String? {
    switch self {
    case .planMissing: "No brief exists for the requested chapter(s) — outline the plan before generating"
    case .planStale(let chapter): "Brief is stale for chapter(s) \(chapter) — refresh the outline or clear staleness before generating"
    case .chapterLocked: "Chapter is locked — finalized prose changes only through amend"
    case .generationRunning: "A generation job is already running for this project — wait for it to finish before regenerating a chapter"
    case .contradiction: "Unresolved contradiction — repair or regenerate the contradicted draft before generating further chapters"
    case .outOfOrder(let chapter, let blocker):
      "Chapter \(chapter) cannot be generated before chapter \(blocker.map(String.init) ?? "undefined") is drafted — chapters are generated in order"
    case .externalChapter(let chapter, let blocker):
      "Chapter \(chapter) cannot be regenerated while chapter \(blocker) is an unfinalized external chapter — fill and finalize it first"
    case .draftExists(let chapter): "Chapter \(chapter) already has a draft — regenerate it from the chapter itself"
    case .teacherUnsettled(let chapter, let teacher): TeachingGateError.teacherUnsettled(chapter: chapter, teacher: teacher).errorDescription
    case .route(_, let description): description
    case .domain(let error): error.errorDescription
    case .engine(let error): error.errorDescription
    }
  }

  init(_ error: StoreError) {
    guard case .aborted(let cause) = error else {
      self = .domain(.store(error))
      return
    }
    switch cause {
    case let cause as GenerationRequestError: self = cause
    case let cause as DomainError: self = .domain(cause)
    default: self = .domain(.store(error))
    }
  }
}

/// What a generate job left: its saves oldest first, its recorded pass, and whether the judged revision is the head (orchestrator decision 6).
public struct GenerationReport: Sendable, Equatable {
  public let revisions: [String]
  public let review: UUID?
  public let judged: String?
  public let isHead: Bool
}

extension JobEngine {
  /// generation.service.ts:224-228: a chapter with a draft is regenerated from the chapter itself.
  public func generateChapter(novel: UUID, chapter: Int, options: GenerationOptions = GenerationOptions(), origin: JSONValue = .null) async throws(GenerationRequestError)
    -> StartedGeneration
  {
    try await startGeneration(novel: novel, chapter: chapter, options: options, origin: origin, regenerating: false)
  }

  /// generation.service.ts:236-273 with its gates in order; asks made together share one run, decided in the request's own write.
  public func regenerateChapter(novel: UUID, chapter: Int, options: GenerationOptions = GenerationOptions(), origin: JSONValue = .null) async throws(GenerationRequestError)
    -> StartedGeneration
  {
    try await startGeneration(novel: novel, chapter: chapter, options: options, origin: origin, regenerating: true)
  }

  /// The generate job behind `generateChapter` (or `regenerateChapter` when `regenerating`), behind the same gates, requested and not started: for a
  /// device that leaves it to the vault's worker.
  public func requestGeneration(
    novel: UUID, chapter: Int, options: GenerationOptions = GenerationOptions(), origin: JSONValue = .null, regenerating: Bool = false
  ) async throws(GenerationRequestError) -> JobKey {
    let (now, unrestrictedAvailable) = (clock.now(), services.unrestrictedAvailable)
    let request: NovelJobRequest
    do {
      request = try await store.write { transaction in
        try GenerationRequests.jobRequest(
          novel: novel, chapter: chapter, options: options, origin: origin, refusingDraft: !regenerating, at: now, unrestrictedAvailable: unrestrictedAvailable,
          in: transaction)
      }
    } catch {
      throw GenerationRequestError(error)
    }
    do throws(JobEngineError) {
      return try await self.request(request)
    } catch {
      throw .engine(error)
    }
  }

  private func startGeneration(
    novel: UUID, chapter: Int, options: GenerationOptions, origin: JSONValue, regenerating: Bool
  ) async throws(GenerationRequestError) -> StartedGeneration {
    let key = try await requestGeneration(novel: novel, chapter: chapter, options: options, origin: origin, regenerating: regenerating)
    do throws(JobEngineError) {
      return .running(try await run(job: key.ref))
    } catch .runningElsewhere {
      return .elsewhere(key.ref)
    } catch {
      throw .engine(error)
    }
  }
}

enum GenerationRequests {
  static func jobRequest(
    novel: UUID, chapter: Int, options: GenerationOptions, origin: JSONValue, refusingDraft: Bool, at now: LeaseInstant, unrestrictedAvailable: Bool,
    in transaction: borrowing WriteTransaction
  ) throws(GenerationRequestError) -> NovelJobRequest {
    guard chapter >= 1 else { throw .engine(.chapterOutOfRange(chapter)) }
    guard options.maxFixes >= 0 else { throw .domain(.belowMinimum(field: "maxFixes", minimum: 0)) }
    let fingerprint = try gate(
      novel: novel, chapter: chapter, refusingDraft: refusingDraft, at: now, unrestrictedAvailable: unrestrictedAvailable, in: transaction)
    let payload = GenerationJobPayload(guidance: options.guidance, autoFix: options.autoFix, maxFixes: options.maxFixes)
    return NovelJobRequest(
      kind: .generate, novel: novel, chapter: chapter, fingerprint: fingerprint, payload: payload.json, origin: origin, rerunOnceSucceeded: true)
  }

  /// The gates of generation.service.ts:224-273 in their order, then the route (AI_024); returns the fingerprint of decision 8, plan revision and upstream.
  static func gate(
    novel: UUID, chapter: Int, refusingDraft: Bool, at now: LeaseInstant, unrestrictedAvailable: Bool, in transaction: borrowing WriteTransaction
  ) throws(GenerationRequestError) -> String {
    let draft = try domain { () throws(DomainError) in try transaction.draft(novel: novel, chapter: chapter) }
    if refusingDraft, case .live = draft { throw .draftExists(chapter) }
    let (plan, upstream) = try domain { () throws(DomainError) in
      try transaction.requireNovel(novel)
      let upstream = try storeCall { () throws(StoreError) in try DraftUpstream.current(novel: novel, chapter: chapter, in: transaction) }
      return (try transaction.planHead(novel: novel, chapter: chapter), upstream)
    }
    guard let plan else { throw .planMissing }
    let entries = try domain { () throws(DomainError) in
      guard try !transaction.lifecycleFaulted(novel: novel) else { throw .lifecycleUnavailable(chapter) }
      return try transaction.lifecycleEntries(novel: novel)
    }
    if entries.first(where: { $0.chapter == chapter })?.planStale != nil { throw .planStale(chapter: chapter) }
    let final = try domain { () throws(DomainError) in try transaction.isFinal(novel: novel, chapter: chapter) }
    var drafted = true
    if case .absent = draft { drafted = false }
    if final && drafted { throw .chapterLocked }
    if try generating(novel: novel, chapter: chapter, at: now, in: transaction) { throw .generationRunning }
    if entries.contains(where: { $0.chapter != chapter && $0.review == .contradiction }) { throw .contradiction }
    if final { throw .chapterLocked }

    let plans = try domain { () throws(DomainError) in try transaction.listing(ChapterPlanRecord.self, novel: novel) }
    let finalized = Set(entries.filter(\.isFinal).map(\.chapter))
    let earlier = Set(entries.filter { $0.draft != nil && $0.chapter != chapter }.map(\.chapter))
    let briefs = plans.map { BatchBrief(chapter: $0.chapter, writeMode: $0.content.writeMode.known ?? .standard) }
    let batch = selectGenerationBatch(briefs, started: earlier, finalized: finalized, limit: 1)
    switch batch.stop {
    case .externalChapter(let blocker): throw .externalChapter(chapter: chapter, blocker: blocker)
    case .unwrittenChapter(let blocker, _): throw .outOfOrder(chapter: chapter, blocker: blocker)
    case nil: break
    }
    guard batch.chapters.first == chapter else { throw .outOfOrder(chapter: chapter, blocker: batch.chapters.first) }
    do throws(TeachingGateError) {
      try assertTeacherSettled(
        briefs: plans.map { TeachingBrief(chapter: $0.chapter, knowledgeContract: knowledgeContractJSON($0.content.contract)) },
        drafts: entries.filter { $0.draft != nil || $0.isFinal }.map { entry in
          TeachingDraft(
            chapter: entry.chapter, status: entry.isFinal ? .final : .draft, reviewStatus: entry.review.flatMap { DraftReviewStatus(rawValue: $0.rawValue) } ?? .needsReview)
        }, chapters: finalized.map { TeachingChapter(number: $0, status: .done) }, before: chapter)
    } catch {
      switch error {
      case .teacherUnsettled(let chapter, let teacher): throw .teacherUnsettled(chapter: chapter, teacher: teacher)
      }
    }

    do {
      _ = try ChapterCallRouter.route(
        ChapterCallSource(novel: novel, chapter: chapter, role: .draft, plan: plan.record.content, isolated: false), unrestrictedAvailable: unrestrictedAvailable)
    } catch {
      throw .route(code: error.code, description: error.errorDescription)
    }
    return ChapterFingerprint.digest(["plan": .string(plan.revision), "upstream": upstream.json])
  }

  /// Any generate job of the novel queued or running, this chapter's own runs included (generation.service.ts:242-243, 260), as the job activity reads it.
  private static func generating(novel: UUID, chapter: Int, at now: LeaseInstant, in transaction: borrowing WriteTransaction) throws(GenerationRequestError) -> Bool {
    try domain { () throws(DomainError) in
      guard try !transaction.faulted(novel: novel, keyedByNovel: [JobActivityRow.databaseTableName]) else { throw .lifecycleUnavailable(chapter) }
      let rows = try transaction.fetch(JobActivityRow.filter(Column("novel") == novel))
      return rows.contains { $0.jobKind == .known(.generate) && $0.status(at: now) != nil }
    }
  }

  /// The plan's knowledge contract in the shape `parseKnowledgeContract` reads (common/knowledge-contract.ts), for the teaching gate.
  static func knowledgeContractJSON(_ contract: ChapterContract) -> OrderedJSON {
    let learns = contract.reveals.map { reveal in OrderedJSON.object(OrderedJSONObject([("entityKey", .string(reveal.entityKey)), ("factKey", .string(reveal.factKey))])) }
    return .object(OrderedJSONObject([("pov", .array(contract.pov.map(OrderedJSON.string))), ("learns", .array(learns))]))
  }

  private static func domain<T>(_ body: () throws(DomainError) -> T) throws(GenerationRequestError) -> T {
    do {
      return try body()
    } catch {
      throw .domain(error)
    }
  }
}

extension VaultStore {
  public func generationReport(novel: UUID, chapter: Int, job: EntityRef) async throws(DomainError) -> GenerationReport {
    do {
      return try await read { transaction in
        let ref = try ChapterRefs.draft(novel: novel, chapter: chapter)
        let history = try DraftRecord.history(ref, in: transaction).history
        let revisions = (history?.revisions.filter { $0.body.body?.job == job.key } ?? []).reversed().map(\.id)
        let review = try ChapterReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).entries.map(\.record).last {
          $0.generationPass && $0.job == job.key
        }
        let judged = review?.draftRevision ?? revisions.last
        return GenerationReport(revisions: revisions, review: review?.id, judged: judged, isHead: judged != nil && history?.head == judged)
      }
    } catch {
      guard case .aborted(let cause as DomainError) = error else { throw .store(error) }
      throw cause
    }
  }
}
