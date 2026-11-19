import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

/// chapter-generation.graph.ts:920-946 as one job, each step checkpointed with its writes; ported from the platform working copy (user decision 2026-11-18).
enum GenerationPipeline {
  static let version = 1
  static let definition = NovelPipelineDefinition.ready(
    NovelPipeline(
      version: version, first: GenerationStep.pin.rawValue, steps: Dictionary(uniqueKeysWithValues: GenerationStep.allCases.map { ($0.rawValue, $0.step) })))
}

enum GenerationStep: String, CaseIterable, Sendable {
  case pin
  case draft
  case expand
  case title
  case save
  case checks
  case judge
  case repair
  case rewrite
  case finish

  var step: any JobStep {
    switch self {
    case .pin: GenerationPinStep()
    case .draft: GenerationDraftStep()
    case .expand: GenerationExpandStep()
    case .title: GenerationTitleStep()
    case .save: GenerationSaveStep()
    case .checks: GenerationChecksStep()
    case .judge: GenerationJudgeStep()
    case .repair: GenerationRepairStep()
    case .rewrite: GenerationRewriteStep()
    case .finish: GenerationFinishStep()
    }
  }
}

enum GenerationJobError: ShadowError {
  case payload
  case checkpoint
  /// A structured reply passed its schema but lacks what the step reads.
  case reply(String)
  case saves(expected: Int, found: Int)
  case route(ChapterCallError)
  case disclosure(DisclosureError)
  case review(ChapterReviewError)
  case domain(DomainError)
  case record(ReviewRecordError)
  case store(StoreError)

  var code: String {
    switch self {
    case .payload: "generation.job_payload"
    case .checkpoint: "generation.job_checkpoint"
    case .reply: "generation.reply"
    case .saves: "generation.saves"
    case .route(let error): error.code
    case .disclosure(let error): error.code
    case .review(let error): error.code
    case .domain(let error): error.code
    case .record(let error): error.code
    case .store(let error): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .payload: "The generate job's request cannot be read."
    case .checkpoint: "The generate job's checkpoint cannot be read."
    case .reply(let name): "The \(name) reply holds no text to use."
    case .saves(let expected, let found): "The run expected \(expected) saved revisions of the chapter and found \(found)."
    case .route(let error): error.errorDescription
    case .disclosure(let error): error.errorDescription
    case .review(let error): error.errorDescription
    case .domain(let error): error.errorDescription
    case .record(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  init(_ error: StoreError) {
    guard case .aborted(let cause) = error else {
      self = .store(error)
      return
    }
    switch cause {
    case let cause as GenerationJobError: self = cause
    case let cause as DomainError: self = .domain(cause)
    default: self = .store(error)
    }
  }
}

extension VaultStore {
  func generationRead<T: Sendable>(_ body: @Sendable (ReadTransaction) throws(GenerationJobError) -> T) async throws(GenerationJobError) -> T {
    do {
      return try await read { transaction in try body(transaction) }
    } catch {
      throw GenerationJobError(error)
    }
  }
}

/// A step's calls: the run's settled mode raised over isolated prose (chapter-generation.graph.ts:91-92, 122-127), the fitting sections, no rendered deltas.
struct GenerationCalls {
  let context: JobStepContext
  let state: GenerationJobState

  var target: ResolvedWordTarget { state.pinned.target.resolved }

  func route(_ role: ChapterRole, isolated: Bool) throws(GenerationJobError) -> ChapterCallRoute {
    do {
      return try ChapterCallRouter.route(
        ChapterCallSource(novel: context.target.novel, chapter: context.target.chapter, role: role, plan: nil, isolated: isolated, raised: state.pinned.unrestricted),
        unrestrictedAvailable: context.unrestrictedAvailable)
    } catch {
      throw .route(error)
    }
  }

  func pack() async throws(JobEngineError) -> (pack: PinnedWriterPack, disclosure: WriterDisclosurePolicy) {
    try await context.writerPack(state.packOptions)
  }

  func sections(_ pack: PinnedWriterPack) -> [ContextSection] {
    pack.sections.map { ContextSection(key: $0.key, rendered: $0.rendered, sourceRefs: $0.sourceRefs) }
  }

  /// The reply as JSON and where it was sent, for the writer snapshot.
  func structured(
    _ route: ChapterCallRoute, _ prompt: ChapterPromptRequest, screening: [(String, String)], sections: [ContextSection], name: String, schema: OrderedJSON
  ) async throws(JobStepCallError) -> (json: JSONValue?, sent: WriterSnapshotRoute?) {
    var sent: WriterSnapshotRoute?
    let result = try await context.call(
      route, pace: state.pinned.pace, screening: OrderedJSONObject(screening.map { ($0.0, OrderedJSON.string($0.1)) }), sections: sections,
      request: { call in
        sent = WriterSnapshotRoute(provider: call.host, model: call.route.model)
        return prompt.modelRequest(model: call.route.model, maxOutputTokens: call.route.maxOutputTokens, effort: call.route.effort)
      }, name: name, schema: JSONValue(schema: schema))
    return (try? CanonicalJSON.decode(result.json), sent)
  }

  /// writer-snapshot-capture.ts:6-16 and the snapshot meta of chapter-generation.graph.ts:498-512, 755-769, 838-852.
  func snapshot(
    _ role: WriterAttemptRole, attempt: Int, prompt: ChapterPromptRequest, disclosure: WriterDisclosurePolicy, omitted: [ChatPackOmission]?, bible: String,
    promptKey: String, promptVersion: String, sent: WriterSnapshotRoute?, isolated: Bool
  ) -> PendingSnapshot? {
    guard let sent else { return nil }
    var withheld: [String: JSONValue] = [:]
    for count in disclosure.withheld { withheld[count.field.rawValue] = .int(Int64(count.count)) }
    let omittedJSON = omitted.flatMap { omitted in (try? JSONEncoder().encode(omitted)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } } ?? .null
    let messages = prompt.messages.map { message in
      WriterSnapshotMessage(role: message.role == .system ? "system" : message.role == .user ? "human" : "ai", content: message.text)
    }
    return PendingSnapshot(
      role: role, attempt: attempt, messages: messages, keptBack: ["withheldForSecrecy": .object(withheld), "omittedForBudget": omittedJSON],
      bibleHash: bible.isEmpty ? nil : sha256Hex(bible), promptKey: promptKey, promptVersion: promptVersion, route: sent, isolated: isolated)
  }

  static func bible(of pack: PinnedWriterPack) -> String {
    [pack.renderedStable, pack.renderedVolatile, pack.rendered].first { !$0.isEmpty } ?? ""
  }

  var isStopping: Bool { context.attempt.isStopping || Task.isCancelled }
}

/// assembleContext (chapter-generation.graph.ts:456-469): mode, pinned pack, scrubbed guidance and what later steps read, so none reads the live store for it.
struct GenerationPinStep: JobStep {
  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let payload = try GenerationJobPayload(json: context.payload)
    let (novel, chapter) = (context.target.novel, context.target.chapter)
    let read = try await context.store.generationRead { transaction throws(GenerationJobError) in
      let plan: ChapterPlanContent?
      do throws(ChapterReviewError) {
        plan = try ChapterReviews.plan(novel: novel, chapter: chapter, in: transaction)
      } catch {
        throw .review(error)
      }
      let novelRecord = try GenerationSaves.stored { () throws(StoreError) in try NovelRecord.read(id: novel, in: transaction) }.entry?.record
      let ref = try GenerationSaves.domain { () throws(DomainError) in try ChapterRefs.draft(novel: novel, chapter: chapter) }
      var head: String?
      switch try GenerationSaves.stored({ () throws(StoreError) in try DraftRecord.read(ref, in: transaction) }) {
      case .absent: break
      case .unreadable: throw .domain(.unreadable(ref))
      case .readable(let entry):
        if !entry.isRemoved { head = try GenerationSaves.stored { () throws(StoreError) in try DraftRecord.history(ref, in: transaction) }.history?.head }
      }
      let load = try GenerationSaves.stored { () throws(StoreError) in try WriterPackLoader.load(novel: novel, chapter: chapter, in: transaction) }
      return (plan: plan, costTier: novelRecord?.costTier.known, wordTarget: novelRecord?.wordTarget, head: head, load: load)
    }
    let route: ChapterCallRoute
    do {
      route = try ChapterCallRouter.route(
        ChapterCallSource(novel: novel, chapter: chapter, role: .draft, plan: read.plan, isolated: false), unrestrictedAvailable: context.unrestrictedAvailable)
    } catch {
      throw GenerationJobError.route(error)
    }
    let unrestricted = route.contentMode == .unrestricted
    let options = WriterPackOptions(permissive: unrestricted, minorNames: read.load.minorNames, enforceReservations: true)
    var (_, disclosure) = try await context.writerPack(options)
    let guidance: String
    do {
      guidance = payload.guidance.isEmpty ? "" : try disclosure.scrub(payload.guidance, .note)
    } catch {
      throw GenerationJobError.disclosure(error)
    }
    let world = read.load.world
    let view = read.plan?.contract.knowledge.map { knowledgeView(in: world.disclosureWorld, chapter: chapter, contract: $0) }
    let judge = GenerationJobState.JudgeInputs(
      pov: read.plan?.pov, briefBody: read.plan?.body, endingContract: read.plan?.endingContract?.json, hidden: view?.hidden.map(JudgeFact.init) ?? [],
      readerKnows: view?.readerKnows.map(JudgeFact.init) ?? [])
    let target = ResolvedWordTarget.resolve(read.wordTarget)
    let pinned = GenerationJobState.Pinned(
      minorNames: read.load.minorNames, unrestricted: unrestricted, pace: read.costTier?.pace ?? .steady,
      target: GenerationJobState.Target(min: target.min, max: target.max, aim: target.aim), guidance: guidance, autoFix: payload.autoFix, maxFixes: payload.maxFixes,
      head: read.head, judge: judge,
      titles: world.finals.map { GenerationJobState.TitleChapter(number: $0.chapter, title: $0.title, isolated: $0.isolated) })
    return AttemptStepOutput(state: try GenerationJobState(pinned: pinned).json, next: GenerationStep.draft.rawValue)
  }
}

/// draftChapter's generation call (chapter-generation.graph.ts:471-521); the prose drafts afresh, so it routes as prose that is not isolated.
struct GenerationDraftStep: JobStep {
  func run(_ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    var state = try GenerationJobState(json: input)
    let calls = GenerationCalls(context: context, state: state)
    let (pinned, disclosure) = try await calls.pack()
    let pack = pinned.pack
    let prompt = chapterGenerationRequest(pack.generationInput(guidance: state.pinned.guidance), target: calls.target)
    let (json, sent) = try await calls.structured(
      try calls.route(.draft, isolated: false), prompt,
      screening: [("chapterBrief", pack.brief.chapterBrief), ("endingContract", pack.brief.endingContract), ("guidance", state.pinned.guidance)],
      sections: calls.sections(pinned), name: "generation", schema: chapterGenerationSchema)
    guard let json, let body = json["body"]?.stringValue else { throw GenerationJobError.reply("generation") }
    state.write(json, body: body)
    state.title = json["title"]?.stringValue ?? ""
    state.snapshots = [
      calls.snapshot(
        .draft, attempt: state.attempt, prompt: prompt, disclosure: disclosure, omitted: pinned.omitted, bible: GenerationCalls.bible(of: pinned),
        promptKey: "generation", promptVersion: chapterGenerationVersion, sent: sent, isolated: state.pinned.unrestricted)
    ].compactMap { $0 }
    return AttemptStepOutput(state: try state.json, next: state.afterWriting.rawValue)
  }
}

extension GenerationJobState {
  fileprivate mutating func write(_ json: JSONValue, body: String) {
    prose = body
    summary = json["summary"]?.stringValue ?? ""
    continuation = json["state"]?.objectValue ?? [:]
    let begun = DraftExpansion.begin(body: body)
    expansion = Expansion(words: begun.words, passes: begun.passes, initialWords: begun.initialWords, stopped: begun.stopped)
  }
}

/// One pass of expandShortDraft (draft-expansion.ts:35-68): a failed, shrinking or runaway pass keeps the body it had and ends the loop.
struct GenerationExpandStep: JobStep {
  private static let logger = Logger(category: "chapter.generation")

  func run(_ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    var state = try GenerationJobState(json: input)
    let calls = GenerationCalls(context: context, state: state)
    guard let expansion = state.expansionState, let request = DraftExpansion.nextRequest(expansion, target: calls.target) else {
      return AttemptStepOutput(state: input, next: state.afterWriting.rawValue)
    }
    let (pinned, _) = try await calls.pack()
    let pack = pinned.pack
    let prompt = chapterExpandRequest(
      ChapterExpandInput(
        stableContext: pack.renderedStable, volatileContext: pack.renderedVolatile, chapterBrief: pack.brief.chapterBrief, endingContract: pack.brief.endingContract,
        guidance: state.writerGuidance, draftBody: request.draftBody, draftWords: Double(request.draftWords), minWords: request.minWords, aimWords: request.aimWords,
        missingWords: request.missingWords))
    let route = try calls.route(.draft, isolated: state.isolated)
    var expanded: String?
    do throws(JobStepCallError) {
      expanded = try await calls.structured(
        route, prompt,
        screening: [
          ("chapterBrief", pack.brief.chapterBrief), ("endingContract", pack.brief.endingContract), ("guidance", state.writerGuidance), ("draftBody", request.draftBody),
        ], sections: calls.sections(pinned), name: "chapter-expand", schema: chapterExpandSchema
      ).json?["body"]?.stringValue
    } catch {
      guard case .call = error, !calls.isStopping else { throw error }
      Self.logger.notice("A draft expansion call failed; keeping the current draft code=\(error.code, privacy: .public) pass=\(request.pass, privacy: .public)")
    }
    state.expand(DraftExpansion.settle(expansion, expandedBody: expanded, target: calls.target))
    return AttemptStepOutput(state: try state.json, next: state.afterWriting.rawValue)
  }
}

/// The title call the drafter's empty title asks for (chapter-generation.graph.ts:523-539).
struct GenerationTitleStep: JobStep {
  func run(_ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    var state = try GenerationJobState(json: input)
    let calls = GenerationCalls(context: context, state: state)
    var (_, disclosure) = try await calls.pack()
    let chapters = state.pinned.titles.map { TitleReferenceChapter(number: $0.number, title: $0.title, isolated: $0.isolated, isDone: true) }
    let input: TitlePromptInput
    do {
      input = try TitlePromptInputs.make(chapter: context.target.chapter, summary: state.summary, chapters: chapters, scrubber: &disclosure)
    } catch {
      throw GenerationJobError.disclosure(error)
    }
    let prompt = ChapterPromptRequest(chapterTitleMessages(existingTitles: input.existingTitles, chapterSummary: input.chapterSummary), layout: .plain, breakpointsAt: [])
    let (json, _) = try await calls.structured(
      try calls.route(.title, isolated: state.isolated), prompt, screening: [("existingTitles", input.existingTitles), ("chapterSummary", input.chapterSummary)],
      sections: [], name: "title", schema: chapterTitleSchema)
    state.title = json?["title"]?.stringValue ?? ""
    return AttemptStepOutput(state: try state.json, next: GenerationStep.save.rawValue)
  }
}

/// persistDraft (chapter-generation.graph.ts:128-218, 561-567), with the upstream pinned at start, the run, the job and the writer attempts behind it.
struct GenerationSaveStep: JobStep {
  func run(_ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    var state = try GenerationJobState(json: input)
    let calls = GenerationCalls(context: context, state: state)
    state.prose = normalizeLineEndings(state.prose)
    let (run, job) = (context.attempt.attempt.uuid.lowercasedString, context.attempt.job.ref.key)
    let content = try calls.route(.draft, isolated: false).contained(
      DraftContent(
        title: state.title, body: state.prose, summary: state.summary, source: .known(RevisionSource.named(attempt: state.attempt, repairMode: state.repairMode)),
        upstream: context.pins.upstream, state: state.continuation, run: run, job: job))
    state.isolated = content.isolated
    let (ordinal, snapshots) = (state.saves, state.snapshots)
    state.saves += 1
    state.snapshots = []
    let (target, head, plan, now) = (context.target, state.pinned.head, context.pins.plan, context.services.now())
    return AttemptStepOutput(state: try state.json, next: GenerationStep.checks.rawValue) { transaction in
      _ = try GenerationSaves.save(
        content, ordinal: ordinal, target: target, run: run, job: job, startedOn: head, plan: plan, snapshots: snapshots, at: now, in: &transaction)
    }
  }
}

/// mechanicalCheck (chapter-generation.graph.ts:569-597) against the last ten earlier final chapters that are not isolated.
struct GenerationChecksStep: JobStep {
  static let priorWindow = 10

  func run(_ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    var state = try GenerationJobState(json: input)
    let (novel, chapter) = (context.target.novel, context.target.chapter)
    let priors = try await context.store.generationRead { transaction throws(GenerationJobError) in
      var bodies: [String] = []
      for earlier in stride(from: chapter - 1, through: 1, by: -1) where bodies.count < Self.priorWindow {
        let ref = try GenerationSaves.domain { () throws(DomainError) in try ChapterRefs.final(novel: novel, chapter: earlier) }
        guard let record = try GenerationSaves.stored({ () throws(StoreError) in try FinalChapterRecord.read(ref, in: transaction) }).entry?.record,
          !record.canon.isolated
        else { continue }
        bodies.append(record.text.body)
      }
      return bodies.filter { !$0.isEmpty }
    }
    let mechanical = MechanicalCheck.checkDraftMechanics(state.prose, priorMarkdown: priors, target: state.pinned.target.resolved)
    let readability = ReadabilityCheck.assessReadability(state.prose)
    state.checks = GenerationJobState.Checks(
      mechanical: mechanical.map { SourcedFinding($0, source: .mechanics) }, readabilityEvidence: readability.map(ReadabilityCheck.renderReadabilityEvidence))
    return AttemptStepOutput(state: try state.json, next: GenerationStep.judge.rawValue)
  }
}

/// judge (chapter-generation.graph.ts:599-731), tool-free (tool-loop.ts:45-48), asked once more with the same messages (:662-666).
struct GenerationJudgeStep: JobStep {
  private static let logger = Logger(category: "chapter.generation")

  func run(_ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    var state = try GenerationJobState(json: input)
    guard let checks = state.checks else { throw GenerationJobError.checkpoint }
    let calls = GenerationCalls(context: context, state: state)
    let (pinned, _) = try await calls.pack()
    let judge = state.pinned.judge
    let contract = judge.contract
    let hidden = judge.hidden.map(\.fact)
    let evaluation = chapterJudgeEvaluation(
      ChapterJudgeEvaluationInput(
        prose: state.prose, pov: judge.pov, briefBody: judge.briefBody, endingContract: contract, hiddenFacts: hidden, readerKnows: judge.readerKnows.map(\.fact),
        readabilityEvidence: checks.readabilityEvidence ?? ""))
    let request = chapterJudgeRequest(contextPack: pinned.rendered, evaluation: evaluation)
    let route = try calls.route(.judge, isolated: state.isolated)
    let sections = calls.sections(pinned)
    let ask = { () async throws(JobStepCallError) -> (report: JudgeReport?, calls: [UUID]) in
      let result = try await context.callText(
        route, pace: state.pinned.pace, screening: OrderedJSONObject([("task", .string(evaluation))]), sections: sections,
        request: { call in ReviewCallStep.judgeRequest(request, for: call) })
      return (try? JudgeReport.parse(result.text), result.callIDs)
    }
    var (report, judgeCalls) = try await ask()
    if report == nil {
      Self.logger.notice("The judge's answer could not be read; asking once more chapter=\(context.target.chapter, privacy: .public)")
      let again = try await ask()
      report = again.report
      judgeCalls += again.calls
    }
    var pass: GenerationJobState.JudgePass
    do {
      pass = try GenerationJudgePass.compose(
        report, prose: state.prose, hasContract: !renderEndingContract(contract).isEmpty, forbidden: hidden.filter { $0.source != .seed },
        mechanical: checks.mechanical)
    } catch {
      throw GenerationJobError.disclosure(error)
    }
    pass.calls = judgeCalls
    pass.route = pass.route(in: state)
    state.pass = pass
    return AttemptStepOutput(state: try state.json, next: (pass.route == .repairPatch ? GenerationStep.repair : .finish).rawValue)
  }
}

/// repairPatch (chapter-generation.graph.ts:733-806); a fix's rewrite body is dropped, as routeAfterPatch sends it to repairRewrite (:774-776, 283-285).
struct GenerationRepairStep: JobStep {
  func run(_ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    var state = try GenerationJobState(json: input)
    guard let pass = state.pass else { throw GenerationJobError.checkpoint }
    let calls = GenerationCalls(context: context, state: state)
    let packed = try await calls.pack()
    let pinned = packed.pack
    var disclosure = packed.disclosure
    let findings: String
    do {
      findings = try WriterFacingFindings.render(
        findings: pass.findings.map(\.finding), knowledgeWriterFindings: pass.knowledgeWriterFindings.map(\.finding), scrubber: &disclosure)
    } catch {
      throw GenerationJobError.disclosure(error)
    }
    let prompt = chapterFixRequest(contextPack: pinned.rendered, prose: state.prose, findings: findings)
    let (json, sent) = try await calls.structured(
      try calls.route(.repair, isolated: state.isolated), prompt, screening: [("prose", state.prose), ("findings", findings)], sections: calls.sections(pinned),
      name: "fix", schema: chapterFixSchema)
    guard let json, let action = json["action"]?.stringValue.flatMap(RepairMode.init(rawValue:)) else { throw GenerationJobError.reply("fix") }
    let patches = json["patches"]?.arrayValue?.compactMap { patch in
      patch["find"]?.stringValue.flatMap { find in patch["replace"]?.stringValue.map { ProsePatch(find: find, replace: $0) } }
    }
    state.snapshots = [
      calls.snapshot(
        .repair, attempt: state.attempt + 1, prompt: prompt, disclosure: disclosure, omitted: nil, bible: pinned.rendered, promptKey: "fix",
        promptVersion: chapterFixVersion, sent: sent, isolated: state.pinned.unrestricted)
    ].compactMap { $0 }
    switch PatchRepair.resolve(RepairProposal(action: action, body: json["body"]?.stringValue, patches: patches), prose: state.prose) {
    case .patched(let patched):
      state.prose = patched
      state.repairMode = .patch
      state.attempt += 1
      state.previousFindings = pass.findings
      return AttemptStepOutput(state: try state.json, next: GenerationStep.save.rawValue)
    case .rewriteBody, .fallBackToRewrite:
      state.repairMode = .rewrite
      return AttemptStepOutput(state: try state.json, next: GenerationStep.rewrite.rawValue)
    }
  }
}

/// repairRewrite (chapter-generation.graph.ts:808-882): a fresh draft told to avoid the findings, expanded as a first draft is.
struct GenerationRewriteStep: JobStep {
  func run(_ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    var state = try GenerationJobState(json: input)
    guard let pass = state.pass else { throw GenerationJobError.checkpoint }
    let calls = GenerationCalls(context: context, state: state)
    let packed = try await calls.pack()
    let pinned = packed.pack
    var disclosure = packed.disclosure
    let findings: String
    do {
      findings = try WriterFacingFindings.render(
        findings: pass.findings.map(\.finding), knowledgeWriterFindings: pass.knowledgeWriterFindings.map(\.finding), scrubber: &disclosure)
    } catch {
      throw GenerationJobError.disclosure(error)
    }
    let author = state.pinned.guidance
    let guidance = author.isEmpty ? "Avoid these issues from the previous draft:\n\(findings)" : "\(author)\n\nPrevious judge findings to avoid:\n\(findings)"
    let pack = pinned.pack
    let prompt = chapterGenerationRequest(pack.generationInput(guidance: guidance), target: calls.target)
    let (json, sent) = try await calls.structured(
      try calls.route(.draft, isolated: state.isolated), prompt,
      screening: [("chapterBrief", pack.brief.chapterBrief), ("endingContract", pack.brief.endingContract), ("guidance", guidance)], sections: calls.sections(pinned),
      name: "generation", schema: chapterGenerationSchema)
    guard let json, let body = json["body"]?.stringValue else { throw GenerationJobError.reply("generation") }
    if let rewritten = calls.snapshot(
      .rewrite, attempt: state.attempt + 1, prompt: prompt, disclosure: disclosure, omitted: pinned.omitted, bible: GenerationCalls.bible(of: pinned),
      promptKey: "generation", promptVersion: chapterGenerationVersion, sent: sent, isolated: state.pinned.unrestricted)
    {
      state.snapshots.append(rewritten)
    }
    state.write(json, body: body)
    if let title = json["title"]?.stringValue, !title.isEmpty { state.title = title }
    state.attempt += 1
    state.previousFindings = pass.findings
    state.repairMode = .rewrite
    state.phase = .rewrite
    state.writerGuidance = guidance
    return AttemptStepOutput(state: try state.json, next: state.afterWriting.rawValue)
  }
}

/// accept, acceptAsIs or awaitReview, then finish (chapter-generation.graph.ts:884-914), in the transaction that ends the attempt.
struct GenerationFinishStep: JobStep {
  private static let logger = Logger(category: "chapter.generation")

  func run(_ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let state = try GenerationJobState(json: input)
    guard let route = state.pass?.route else { throw GenerationJobError.checkpoint }
    let (target, attempt, job) = (context.target, context.attempt.attempt, context.attempt.job.ref.key)
    let run = attempt.uuid.lowercasedString
    Self.logger.info("A generation run ended route=\(route.rawValue, privacy: .public) chapter=\(target.chapter, privacy: .public) attempt=\(state.attempt, privacy: .public)")
    return AttemptStepOutput(state: input, next: nil) { transaction in
      _ = try GenerationSaves.finish(state, target: target, run: run, job: job, attempt: attempt, in: &transaction)
    }
  }
}
