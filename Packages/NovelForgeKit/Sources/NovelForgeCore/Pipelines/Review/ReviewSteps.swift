import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText

/// A judge or editorial review of one named revision as a job (apps/novel-forge-server/src/modules/review/chapter-review.service.ts:143-154, 236-305):
/// `prepare` reads the text, the author's settled answers and the writer pack and keeps the prompt in the checkpoint; `review` makes the one model call and
/// appends the review in the transaction that ends the attempt, so a resumed attempt never stores it twice.
enum ReviewPipeline {
  static let version = 1
  static let definition = NovelPipelineDefinition.ready(
    NovelPipeline(
      version: version, first: ReviewStep.prepare.rawValue,
      steps: [ReviewStep.prepare.rawValue: ReviewPrepareStep(), ReviewStep.review.rawValue: ReviewCallStep()],
      course: PipelineCourse([ReviewStep.prepare.rawValue, ReviewStep.review.rawValue], tasks: [ReviewStep.review.rawValue: .review])))
}

enum ReviewStep: String {
  case prepare
  case review
}

/// What a review job is asked for. The fingerprint is the revision and kind (orchestrator decision 8) with the body, which tells apart a final chapter's
/// amendments under its canon's one revision, and the raise and pace, so an unrestricted or deeper ask never joins another's job.
struct ReviewJobPayload: Codable, Equatable, Sendable {
  let kind: String
  let revision: String?
  let unrestricted: Bool
  let pace: Pace?

  var reviewKind: ChapterReviewKind? { ChapterReviewKind(rawValue: kind).flatMap { ChapterReviews.modelKinds.contains($0) ? $0 : nil } }

  func fingerprint(source: ReviewSource) -> String {
    ChapterFingerprint.digest([
      "kind": .string(kind), "revision": source.draftRevision.map(JSONValue.string) ?? .null, "body": .string(source.bodyHash), "unrestricted": .bool(unrestricted),
      "pace": pace.map { .string($0.rawValue) } ?? .null,
    ])
  }
}

struct ReviewJobState: Codable, Equatable, Sendable {
  struct Judge: Codable, Equatable, Sendable {
    struct Leak: Codable, Equatable, Sendable {
      let factKey: String
      let term: String
      let excerpt: String
    }

    let task: String
    let hasEndingContract: Bool
    let lockedFromReader: [String]
    let hiddenFromCast: [String]
    let leaks: [Leak]
  }

  struct Editorial: Codable, Equatable, Sendable {
    let chapterBrief: String
    let settledFindings: String
  }

  enum Prompt: Codable, Equatable, Sendable {
    case judge(Judge)
    case editorial(Editorial)
  }

  let source: ReviewSource
  /// The chapter's route was unrestricted: its mode, its isolated prose or the request raised it.
  let unrestricted: Bool
  let pace: Pace
  let hasBrief: Bool
  let contextPack: String
  let sections: [ContextSectionState]
  let prompt: Prompt
}

struct ContextSectionState: Codable, Equatable, Sendable {
  let key: String
  let rendered: String
  let sourceRefs: [String]

  var section: ContextSection { ContextSection(key: key, rendered: rendered, sourceRefs: sourceRefs) }
}

enum ReviewJobError: ShadowError {
  case payload
  case checkpoint
  case disclosure(DisclosureError)
  case route(ChapterCallError)

  var code: String {
    switch self {
    case .payload: "chapter_review.job_payload"
    case .checkpoint: "chapter_review.job_checkpoint"
    case .disclosure(let error): error.code
    case .route(let error): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .payload: "The review job does not name a judge or editorial review."
    case .checkpoint: "The review job's checkpoint cannot be read."
    case .disclosure(let error): error.errorDescription
    case .route(let error): error.errorDescription
    }
  }
}

extension ReviewJobState {
  var json: JSONValue {
    get throws(ReviewJobError) {
      guard let data = try? JSONEncoder().encode(self), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw .checkpoint }
      return json
    }
  }

  init(json: JSONValue) throws(ReviewJobError) {
    guard let state = try? JSONDecoder().decode(Self.self, from: CanonicalJSON.encode(json)) else { throw .checkpoint }
    self = state
  }

  var reviewKind: ChapterReviewKind {
    switch prompt {
    case .judge: .judge
    case .editorial: .editorial
    }
  }

  /// The route `prepare` found, rebuilt from what it kept: a chapter whose mode was unrestricted is raised, which routes and contains as its plan did.
  func route(novel: UUID, chapter: Int, unrestrictedAvailable: Bool) throws(ReviewJobError) -> ChapterCallRoute {
    let role: ChapterRole = reviewKind == .judge ? .judge : .review
    do {
      return try ChapterCallRouter.route(
        ChapterCallSource(novel: novel, chapter: chapter, role: role, plan: nil, isolated: source.isolated, raised: unrestricted),
        unrestrictedAvailable: unrestrictedAvailable)
    } catch {
      throw .route(error)
    }
  }

  /// chapter-review.service.ts:261 and review-records.ts:62: isolated prose, or a review that ran unrestricted.
  var isolated: Bool { source.isolated || unrestricted }
}

/// A job reviews the revision it was requested for, read when it runs, where the reference re-reads the chapter as it then stands
/// (chapter-review.service.ts:236-237); a review of a revision the head has since left is stored stale and gates nothing.
struct ReviewPrepareStep: JobStep {
  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    guard let payload = try? JSONDecoder().decode(ReviewJobPayload.self, from: CanonicalJSON.encode(context.payload)), let kind = payload.reviewKind else {
      throw ReviewJobError.payload
    }
    let (novel, chapter, now) = (context.target.novel, context.target.chapter, context.services.now())
    let read = try await context.store.reviewRead { transaction throws(ChapterReviewError) in
      let source = try ChapterReviews.source(novel: novel, chapter: chapter, revision: payload.revision, in: transaction)
      if !source.final, try ChapterReviews.isGenerating(novel: novel, chapter: chapter, at: now, in: transaction) { throw .generating(chapter) }
      let plan = try ChapterReviews.plan(novel: novel, chapter: chapter, in: transaction)
      let settled = try ChapterReviews.settled(novel: novel, chapter: chapter, kind: kind, text: source.reviewed, in: transaction)
      let costTier = try ChapterReviews.stored { () throws(StoreError) in try NovelRecord.read(id: novel, in: transaction) }.entry?.record.costTier.known
      let load = try ChapterReviews.stored { () throws(StoreError) in try WriterPackLoader.load(novel: novel, chapter: chapter, in: transaction) }
      return (source: source, plan: plan, settled: settled, pace: costTier?.pace ?? .steady, load: load)
    }
    let route: ChapterCallRoute
    do {
      route = try ChapterCallRouter.route(
        ChapterCallSource(novel: novel, chapter: chapter, role: kind == .judge ? .judge : .review, plan: read.plan, isolated: read.source.isolated, raised: payload.unrestricted),
        unrestrictedAvailable: context.unrestrictedAvailable)
    } catch {
      throw ReviewJobError.route(error)
    }
    let unrestricted = route.contentMode == .unrestricted
    let (pack, disclosure) = try await context.writerPack(WriterPackOptions(permissive: unrestricted, minorNames: read.load.minorNames))
    let hasBrief = read.plan != nil
    let body = read.source.body
    let prompt: ReviewJobState.Prompt =
      kind == .judge
      ? .judge(
        try Self.judgeInputs(
          body: body, chapter: chapter, chapterBrief: hasBrief ? pack.chapterBrief : nil, endingContract: pack.endingContract, locked: disclosure.lockedFacts,
          world: read.load.world, settled: read.settled))
      : .editorial(
        ReviewJobState.Editorial(
          chapterBrief: editorialChapterBrief(plan: hasBrief ? pack.chapterBrief : nil, endingContract: pack.endingContract),
          settledFindings: ReviewPrompts.renderSettledFindings(read.settled)))
    let prepared = ReviewJobState(
      source: read.source, unrestricted: unrestricted, pace: payload.pace ?? read.pace, hasBrief: hasBrief, contextPack: pack.rendered,
      sections: pack.sections.map { ContextSectionState(key: $0.key, rendered: $0.rendered, sourceRefs: $0.sourceRefs) }, prompt: prompt)
    return AttemptStepOutput(state: try prepared.json, next: ReviewStep.review.rawValue)
  }

  /// chapter-review.service.ts:313-335: the facts locked from the reader and those hidden from the point-of-view cast, the give-away words the prose
  /// already holds, and the task the judge reads.
  static func judgeInputs(
    body: String, chapter: Int, chapterBrief: String?, endingContract: String, locked: [DisclosureFact], world: WriterPackWorld, settled: [SettledFinding]
  ) throws(ReviewJobError) -> ReviewJobState.Judge {
    let disclosureWorld = world.disclosureWorld
    let hidden = world.plan(for: chapter)?.knowledge.map { knowledgeView(in: disclosureWorld, chapter: chapter, contract: $0).hidden } ?? []
    let readerVisible = writerVisibleFactKeys(in: disclosureWorld, chapter: chapter, facts: world.facts.jsStableSorted(by: factKeyPrecedes), contract: nil)
    let forbidden = uniqueFacts(locked + hidden).filter { $0.source != .seed }
    let lockedFromReader = forbidden.filter { !readerVisible.contains(JSString($0.factKey)) }
    let hiddenFromCast = forbidden.filter { readerVisible.contains(JSString($0.factKey)) }
    let leaks: [KnowledgeLeakIssue]
    do {
      leaks = lockedFromReader.isEmpty ? [] : try scanKnowledgeLeaks(body, hidden: lockedFromReader)
    } catch {
      throw .disclosure(error)
    }
    let readability = ReadabilityCheck.assessReadability(body).map(ReadabilityCheck.renderReadabilityEvidence)
    let task = ReviewPrompts.renderJudgeTask(
      JudgeTask(
        body: body, chapterBrief: chapterBrief, endingContract: endingContract, lockedFromReader: lockedFromReader, hiddenFromCast: hiddenFromCast,
        readabilityEvidence: readability, settled: settled))
    return ReviewJobState.Judge(
      task: task, hasEndingContract: !endingContract.isEmpty, lockedFromReader: lockedFromReader.map(\.factKey), hiddenFromCast: hiddenFromCast.map(\.factKey),
      leaks: leaks.map { ReviewJobState.Judge.Leak(factKey: $0.factKey, term: $0.term, excerpt: $0.excerpt) })
  }

  /// A JavaScript `Map` keyed by fact key: the first fact's position, the last one's value (chapter-review.service.ts:543-545).
  static func uniqueFacts(_ facts: [DisclosureFact]) -> [DisclosureFact] {
    var order: [String] = []
    var byKey: [String: DisclosureFact] = [:]
    for fact in facts {
      if byKey.updateValue(fact, forKey: fact.factKey) == nil { order.append(fact.factKey) }
    }
    return order.compactMap { byKey[$0] }
  }
}

struct ReviewCallStep: JobStep {
  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let prepared = try ReviewJobState(json: state)
    let (novel, chapter) = (context.target.novel, context.target.chapter)
    let route = try prepared.route(novel: novel, chapter: chapter, unrestrictedAvailable: context.unrestrictedAvailable)
    let (outcome, calls): (ReviewOutcome, [UUID])
    switch prepared.prompt {
    case .judge(let judge): (outcome, calls) = try await self.judge(judge, prepared, route: route, in: context)
    case .editorial(let editorial): (outcome, calls) = try await self.editorial(editorial, prepared, route: route, in: context)
    }
    let (kind, source, isolated) = (prepared.reviewKind, prepared.source, prepared.isolated)
    let (job, attempt) = (context.attempt.job.ref.key, context.attempt.attempt)
    return AttemptStepOutput(state: state, next: nil) { transaction in
      try ChapterReviews.append(
        outcome, kind: kind, novel: novel, chapter: chapter, source: source, isolated: isolated, id: attempt.uuid, job: job, attempt: attempt, calls: calls,
        in: &transaction)
    }
  }

  /// chapter-review.service.ts:337-365, tool-free (tool-loop.ts:45-48; orchestrator decision 5): a reply the full judge schema (`JudgeReport`) cannot read is
  /// asked once more with the same messages (:351-355), and one still unreadable stores a failed review.
  private func judge(_ judge: ReviewJobState.Judge, _ prepared: ReviewJobState, route: ChapterCallRoute, in context: JobStepContext) async throws -> (
    ReviewOutcome, [UUID]
  ) {
    let request = chapterJudgeRequest(contextPack: prepared.contextPack, evaluation: judge.task)
    let ask = { () async throws(JobStepCallError) -> (output: JudgeOutput?, calls: [UUID]) in
      let result = try await context.callText(
        route, pace: prepared.pace, screening: OrderedJSONObject([("task", .string(judge.task))]), sections: prepared.sections.map(\.section),
        request: { call in Self.judgeRequest(request, for: call) })
      return ((try? JudgeReport.parse(result.text)).map(JudgeOutput.init), result.callIDs)
    }
    var (output, calls) = try await ask()
    if output == nil {
      Self.logger.notice("The judge's answer could not be read; asking once more chapter=\(context.target.chapter, privacy: .public)")
      let again = try await ask()
      output = again.output
      calls += again.calls
    }
    let facts = { (keys: [String]) in keys.map { DisclosureFact(factKey: $0, text: "") } }
    let evidence = JudgeEvidence(
      output: output, hasBrief: prepared.hasBrief, hasEndingContract: judge.hasEndingContract, lockedFromReader: facts(judge.lockedFromReader),
      hiddenFromCast: facts(judge.hiddenFromCast), leaks: judge.leaks.map { KnowledgeLeakIssue(factKey: $0.factKey, term: $0.term, excerpt: $0.excerpt) })
    return (ReviewFindings.judgeOutcome(body: prepared.source.body, evidence: evidence), calls)
  }

  private static let logger = Logger(category: "chapter.review")

  /// The judge prompt's JSON response format where the route's model takes a native schema (model-router.service.ts:386, 406), in the form it can be sent;
  /// otherwise the plain text the judge's own instructions already shape as JSON.
  static func judgeRequest(_ prompt: ChapterPromptRequest, for call: RoutedCall) -> ModelRequest {
    var request = prompt.modelRequest(model: call.route.model, maxOutputTokens: call.route.maxOutputTokens, effort: call.route.effort)
    guard case .json(let name, let schema) = request.format, call.route.supportsNativeSchema, let native = StructuredSchema.nativeForm(of: schema) else {
      request.format = .text
      return request
    }
    request.format = .json(name: name, schema: native)
    return request
  }

  // apps/novel-forge-server/src/modules/review/chapter-review.service.ts:368-384
  private func editorial(_ editorial: ReviewJobState.Editorial, _ prepared: ReviewJobState, route: ChapterCallRoute, in context: JobStepContext) async throws -> (
    ReviewOutcome, [UUID]
  ) {
    let body = prepared.source.body
    let request = editorialReviewRequest(
      contextPack: prepared.contextPack, chapterBrief: editorial.chapterBrief, draftBody: body, settledFindings: editorial.settledFindings)
    let result = try await context.call(
      route, pace: prepared.pace,
      screening: OrderedJSONObject([
        ("chapterBrief", .string(editorial.chapterBrief)), ("draftBody", .string(body)), ("settledFindings", .string(editorial.settledFindings)),
      ]), sections: prepared.sections.map(\.section),
      request: { call in request.modelRequest(model: call.route.model, maxOutputTokens: call.route.maxOutputTokens, effort: call.route.effort) },
      name: editorialReviewSchemaName, schema: JSONValue(schema: editorialReviewSchema), review: .decoding(EditorialReviewOutput.self))
    let output = try EditorialReviewOutput(data: result.json)
    return (ReviewFindings.editorialOutcome(body: body, output: ReviewOutput(output), hasBrief: prepared.hasBrief), result.callIDs)
  }
}

extension JudgeOutput {
  init(_ report: JudgeReport) {
    let compliance = { (value: JudgeCompliance?) in value.map { ReviewCompliance(compliant: $0.compliant, issues: $0.issues) } }
    self.init(
      verdict: report.verdict.rawValue, findings: report.findings.map { JudgeOutputFinding(severity: $0.severity == .hard ? .hard : .soft, text: $0.text) },
      endingCompliance: compliance(report.endingCompliance), knowledgeCompliance: compliance(report.knowledgeCompliance),
      briefCompliance: compliance(report.briefCompliance), readabilityCompliance: compliance(report.readabilityCompliance))
  }
}

extension ReviewOutput {
  init(_ output: EditorialReviewOutput) {
    self.init(
      disposition: output.disposition == .approve ? .approve : .revisionRequested, note: output.note,
      findings: output.findings?.map { EditorialFinding(severity: $0.severity == .blocking ? .blocking : .suggestion, text: $0.text, evidence: $0.evidence) },
      proofreading: output.proofreading?.map { ProofreadSlip(kind: ProofreadKind(output: $0.kind), quote: $0.quote, fix: $0.fix, reason: $0.reason) })
  }
}

extension ProofreadKind {
  fileprivate init(output kind: EditorialReviewOutput.SlipKind) {
    switch kind {
    case .grammar: self = .grammar
    case .spelling: self = .spelling
    case .punctuation: self = .punctuation
    case .tense: self = .tense
    case .pov: self = .pov
    case .name: self = .name
    case .reference: self = .reference
    }
  }
}
