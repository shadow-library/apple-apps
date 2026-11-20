import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText

enum FinalizeReviewPipelineError: ShadowError {
  case malformedState(step: String)
  case unreadableExtraction

  var code: String {
    switch self {
    case .malformedState: "finalize_review.malformed_state"
    case .unreadableExtraction: "finalize_review.unreadable_extraction"
    }
  }

  var errorDescription: String? {
    switch self {
    case .malformedState(let step): "The finalize review's \(step) step was given a state it cannot read."
    case .unreadableExtraction: "The continuity extraction could not be read as the schema it passed."
    }
  }
}

/// The finalize_review job (apps/novel-forge-server/src/modules/finalize-review/finalize-review.service.ts:424-467): the continuity call reads the approved
/// revision, the review it yields is appended once ready, and a standard chapter with nothing left to ask is finalized through `finalize`, whose refusals leave
/// the review waiting and never fail the job.
enum FinalizeReviewPipeline {
  static let version = 1

  /// What finalizing on approval commits: the gated commit, as approval asks for it, so it refuses everything `FinalizeReadiness` refuses and an isolated chapter.
  typealias Finalize = @Sendable (_ novel: UUID, _ chapter: Int, _ transaction: inout WriteTransaction) throws(DomainError) -> Void

  static let commit: Finalize = { novel, chapter, transaction throws(DomainError) in
    _ = try ChapterFinalize.finalize(novel: novel, chapter: chapter, by: .approval, in: &transaction)
  }

  static let definition = NovelPipelineDefinition.ready(pipeline())

  static let logger = Logger(category: "finalize_review.pipeline")

  enum Step: String {
    case extract
    case store
    case settle
  }

  static func pipeline(finalizing finalize: @escaping Finalize = commit) -> NovelPipeline {
    NovelPipeline(
      version: version, first: Step.extract.rawValue,
      steps: [Step.extract.rawValue: ExtractStep(), Step.store.rawValue: StoreStep(), Step.settle.rawValue: SettleStep(finalize: finalize)])
  }

  /// The review this job already appended, from any of its attempts: the first ready one is the one the job keeps (G11).
  static func appended(job: EntityKey, novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) -> FinalizeReviewRecord? {
    try storeCall { () throws(StoreError) in try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction) }.records.first { $0.job == job }
  }

  /// The head the input was approved at, or nil once the prose moved past it or the chapter is final (finalize-review.service.ts:430).
  static func approvedHead(_ input: FinalizeReviewJobInput, novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) -> DraftHead? {
    guard try !transaction.isFinal(novel: novel, chapter: chapter), case .live(let head) = try transaction.draft(novel: novel, chapter: chapter),
      input.reads(head.revision, body: head.content.body)
    else { return nil }
    return head
  }

  static func input(_ state: JSONValue, step: Step) throws(FinalizeReviewPipelineError) -> FinalizeReviewJobInput {
    guard let input = FinalizeReviewJobInput(json: state[StateMember.input.rawValue] ?? state) else { throw .malformedState(step: step.rawValue) }
    return input
  }

  enum StateMember: String {
    case input
    case isolated
    case extraction
  }
}

/// finalize-review.service.ts:485-492: one continuity call over the approved prose, routed by the chapter's isolation alone.
struct ExtractStep: JobStep {
  private enum Reading: Sendable {
    case moved
    case appended
    case prose(body: String, isolated: Bool, contextPack: String, pace: Pace)
  }

  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let input = try FinalizeReviewPipeline.input(state, step: .extract)
    let (novel, chapter, job) = (context.target.novel, context.target.chapter, context.attempt.job.ref.key)
    let reading = try await context.store.writeDomain { transaction throws(DomainError) -> Reading in
      guard let head = try FinalizeReviewPipeline.approvedHead(input, novel: novel, chapter: chapter, in: transaction) else { return .moved }
      if try FinalizeReviewPipeline.appended(job: job, novel: novel, chapter: chapter, in: transaction) != nil { return .appended }
      let read = try FinalizeReviewNovel.load(novel: novel, chapter: chapter, in: transaction)
      return .prose(body: head.content.body, isolated: head.content.isolated, contextPack: read.contextPack, pace: read.pace)
    }
    let settled: JSONValue = [FinalizeReviewPipeline.StateMember.input.rawValue: input.json]
    switch reading {
    case .moved:
      FinalizeReviewPipeline.logger.info("Finalize review skipped: the prose moved past the approved revision chapter=\(chapter, privacy: .public)")
      return AttemptStepOutput(state: settled, next: nil)
    case .appended:
      return AttemptStepOutput(state: settled, next: FinalizeReviewPipeline.Step.settle.rawValue)
    case .prose(let body, let isolated, let contextPack, let pace):
      let route = try ChapterCallRouter.route(
        ChapterCallSource(novel: novel, chapter: chapter, role: .continuity, plan: nil, isolated: isolated), unrestrictedAvailable: context.unrestrictedAvailable)
      let shown = isolated ? continuityIsolatedContext(contextPack) : contextPack
      let request = continuityRequest(contextPack: contextPack, chapter: chapter, prose: body, isolated: isolated)
      let result = try await context.call(
        route, pace: pace,
        screening: OrderedJSONObject([("contextPack", .string(shown)), ("chapterNumber", .int(Int64(chapter))), ("chapterProse", .string(body))]),
        request: { call in request.modelRequest(model: call.route.model, maxOutputTokens: call.route.maxOutputTokens, effort: call.route.effort) },
        name: continuitySchemaName, schema: JSONValue(schema: continuitySchema))
      guard (try? ContinuityOutput(data: result.json)) != nil, let extraction = try? CanonicalJSON.decode(result.json, mode: .lenient) else {
        throw FinalizeReviewPipelineError.unreadableExtraction
      }
      let next: JSONValue = [
        FinalizeReviewPipeline.StateMember.input.rawValue: input.json, FinalizeReviewPipeline.StateMember.isolated.rawValue: .bool(isolated),
        FinalizeReviewPipeline.StateMember.extraction.rawValue: extraction,
      ]
      return AttemptStepOutput(state: next, next: FinalizeReviewPipeline.Step.store.rawValue)
    }
  }
}

/// finalize-review.service.ts:494-512, 518-561: the items are built against the novel as the commit reads it and appended, with the attempt's id, in the
/// checkpoint's transaction, unless this job already appended a review; answers carry over at read time (`FinalizeReviewChain`), never by rewriting a read.
struct StoreStep: JobStep {
  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let input = try FinalizeReviewPipeline.input(state, step: .store)
    guard let isolated = state[FinalizeReviewPipeline.StateMember.isolated.rawValue]?.boolValue,
      let stored = state[FinalizeReviewPipeline.StateMember.extraction.rawValue]
    else { throw FinalizeReviewPipelineError.malformedState(step: FinalizeReviewPipeline.Step.store.rawValue) }
    guard let output = try? ContinuityOutput(data: CanonicalJSON.encode(stored)) else { throw FinalizeReviewPipelineError.unreadableExtraction }
    let (novel, chapter, attempt, job) = (context.target.novel, context.target.chapter, context.attempt.attempt, context.attempt.job.ref.key)
    let extraction = output.finalizeExtraction
    let next: JSONValue = [FinalizeReviewPipeline.StateMember.input.rawValue: input.json]
    return AttemptStepOutput(state: next, next: FinalizeReviewPipeline.Step.settle.rawValue) { transaction in
      guard try FinalizeReviewRecord.read(FinalizeReviewRecord.ref(attempt: attempt), in: transaction) == .absent,
        try FinalizeReviewPipeline.appended(job: job, novel: novel, chapter: chapter, in: transaction) == nil
      else { return }
      let read = try FinalizeReviewNovel.load(novel: novel, chapter: chapter, in: transaction)
      let items = buildReviewItems(read.material(extraction, isolated: isolated)).enumerated().map { position, item in
        StoredFinalizeItem(
          key: item.itemKey, position: position, category: .known(item.category), triage: .known(item.triage), basis: .known(item.basis), subject: item.subjectKey,
          claim: item.claim, evidence: item.evidence, proposed: item.proposed.json.objectValue ?? [:], flag: item.flag.map(StoredEnum.known),
          dependents: item.dependents, autoDecision: item.autoKept ? .known(.kept) : nil)
      }
      let record = try FinalizeReviewRecord(
        attempt: attempt, job: job, novel: novel, chapter: chapter, draftRevision: input.revision, sourceHash: input.sourceHash, planHash: input.plan,
        isolated: isolated, items: items)
      _ = try record.append(in: &transaction)
      FinalizeReviewPipeline.logger.info("Finalize review prepared chapter=\(chapter, privacy: .public) items=\(items.count, privacy: .public)")
    }
  }
}

/// finalize-review.service.ts:452-467: approving answered everything kept on its own, so a standard chapter whose review in force asks nothing more is finalized;
/// an isolated one is finalized only by its author (decision 12). Anything that refuses leaves the review waiting, and a resume after the commit finds the
/// chapter final.
struct SettleStep: JobStep {
  private enum Settled: Sendable {
    case moved
    case isolated
    case waiting(String)
    case finalized
  }

  let finalize: FinalizeReviewPipeline.Finalize

  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let input = try FinalizeReviewPipeline.input(state, step: .settle)
    let (novel, chapter, finalize) = (context.target.novel, context.target.chapter, finalize)
    let done = AttemptStepOutput(state: state, next: nil)
    let settled: Settled
    do throws(DomainError) {
      settled = try await context.store.writeDomain { transaction throws(DomainError) -> Settled in
        guard let head = try FinalizeReviewPipeline.approvedHead(input, novel: novel, chapter: chapter, in: transaction) else { return .moved }
        let (chain, answers) = try FinalizeReviewChain.reads(novel: novel, chapter: chapter, head: head.revision, in: transaction)
        guard let review = chain.last else { return .moved }
        if review.record.isolated || head.content.isolated { return .isolated }
        let revision = ReviewedRevision(revision: head.revision, body: head.content.body)
        if let blocker = FinalizeReviewChain.blocker(chain: chain, answers: answers, head: revision) { return .waiting(blocker.code) }
        try finalize(novel, chapter, &transaction)
        return .finalized
      }
    } catch {
      FinalizeReviewPipeline.logger.notice("Chapter not finalized on approval chapter=\(chapter, privacy: .public) code=\(error.code, privacy: .public)")
      return done
    }
    switch settled {
    case .moved: FinalizeReviewPipeline.logger.info("Finalize review settled nothing: the prose moved or the chapter is final chapter=\(chapter, privacy: .public)")
    case .isolated: FinalizeReviewPipeline.logger.info("Isolated chapter left for the author to finalize chapter=\(chapter, privacy: .public)")
    case .waiting(let code): FinalizeReviewPipeline.logger.info("Finalize review answered in part chapter=\(chapter, privacy: .public) code=\(code, privacy: .public)")
    case .finalized: FinalizeReviewPipeline.logger.info("Chapter finalized on approval chapter=\(chapter, privacy: .public)")
    }
    return done
  }
}
