import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText
import Synchronization

/// One step of a Novel Forge pipeline: one model call at most, its output and next checkpoint written in one transaction by the runner (orchestrator
/// decision 6). A chapter call goes only through `JobStepContext.call`, and only what that returns is saved or checkpointed; the writer pack and the policy
/// that scrubs anything else shown to the writer come only from `JobStepContext.writerPack`.
protocol JobStep: Sendable {
  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput
}

struct NovelPipeline: Sendable {
  /// Raised when a step's state or meaning changes: an attempt pinned to another version fails rather than resuming into a checkpoint it cannot read.
  let version: Int
  let first: String
  let steps: [String: any JobStep]
  let course: PipelineCourse?

  init(version: Int, first: String, steps: [String: any JobStep], course: PipelineCourse? = nil) {
    self.version = version
    self.first = first
    self.steps = steps
    self.course = course
  }
}

enum NovelPipelineDefinition: Sendable {
  case ready(NovelPipeline)
  case notYetAvailable(NovelJobKind)
}

/// What a pack build returns: the pack, the policy it was scrubbed by, and the sources that policy was built from.
typealias WriterPackBuilder =
  @Sendable (_ novel: UUID, _ chapter: Int, _ options: WriterPackOptions) async throws(WriterPackError) -> (
    pack: WriterPack, disclosure: WriterDisclosurePolicy, sources: WriterDisclosureSources
  )

/// `VaultStore.writerPack`, keeping the sources of the policy the pack was scrubbed by.
// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:193-226
func vaultWriterPack(_ store: VaultStore) -> WriterPackBuilder {
  { novel, chapter, options throws(WriterPackError) in
    let load: WriterPackLoad
    do throws(StoreError) {
      load = try await store.read { transaction in try WriterPackLoader.load(novel: novel, chapter: chapter, in: transaction) }
    } catch {
      throw .store(error)
    }
    guard load.unreadable.isEmpty else { throw .unreadable(load.unreadable) }
    return try WriterPackAssembler.assemble(load, chapter: chapter, options: options)
  }
}

struct JobServices: Sendable {
  let store: VaultStore
  let router: JobEngine.RouterSource
  let consent: AIConsentRequirement
  let unrestrictedAvailable: Bool
  let hardLines: NovelHardLines
  let packs: WriterPackBuilder
  let retrieval: NovelRetrieval
  let progress: RunProgressBoard
  let now: @Sendable () -> Date
}

struct JobStepContext: Sendable {
  let attempt: AttemptStepContext
  let target: NovelJobTarget
  let pins: JobPins
  let services: JobServices

  var store: VaultStore { services.store }
  var consent: AIConsentRequirement { services.consent }
  var unrestrictedAvailable: Bool { services.unrestrictedAvailable }
  var payload: JSONValue { attempt.job.request.payload }

  /// `route.run` with one read of the novel's minor names behind its input screen, its request guard and its output screen alike.
  func call(
    _ route: ChapterCallRoute, pace: Pace, thinksDeeper: Bool = false, screening input: OrderedJSONObject, sections: [ContextSection] = [],
    request: (RoutedCall) -> ModelRequest, name: String, schema: JSONValue, review: StructuredReview = .none, observer: (StructuredStreamEvent) -> Void = { _ in }
  ) async throws(JobStepCallError) -> StructuredResult {
    try await services.call(
      route, pace: pace, thinksDeeper: thinksDeeper, screening: input, sections: sections, request: request, name: name, schema: schema, review: review,
      observer: observer)
  }

  /// `route.runText` behind the same screens, for a reply the step parses itself.
  func callText(
    _ route: ChapterCallRoute, pace: Pace, thinksDeeper: Bool = false, screening input: OrderedJSONObject, sections: [ContextSection] = [],
    request: (RoutedCall) -> ModelRequest
  ) async throws(JobStepCallError) -> ChapterTextResult {
    try await services.callText(route, pace: pace, thinksDeeper: thinksDeeper, screening: input, sections: sections, request: request)
  }

  /// The attempt's writer pack under `options`, built once and kept on this device for the attempt's later steps and its resumes, with the disclosure policy
  /// it was scrubbed by, rebuilt from the kept sources so every step scrubs as the build did.
  func writerPack(_ options: WriterPackOptions) async throws(JobEngineError) -> (pack: PinnedWriterPack, disclosure: WriterDisclosurePolicy) {
    let pinned = try await pinnedPack(options)
    do {
      return (pinned, try pinned.disclosurePolicy())
    } catch {
      throw .writerPack(code: error.code, description: error.errorDescription)
    }
  }

  private func pinnedPack(_ options: WriterPackOptions) async throws(JobEngineError) -> PinnedWriterPack {
    let (store, id) = (services.store, attempt.attempt)
    do {
      if let pinned = try await store.read({ transaction in try WriterPackPins.pinned(id, options: options, in: transaction.database) }) { return pinned }
    } catch {
      throw .store(error)
    }
    let built: (pack: WriterPack, disclosure: WriterDisclosurePolicy, sources: WriterDisclosureSources)
    do {
      built = try await services.packs(target.novel, target.chapter, options)
    } catch {
      throw JobEngineError(error)
    }
    let pack = PinnedWriterPack(built.pack, disclosure: built.disclosure, sources: built.sources)
    let now = services.now()
    do {
      return try await store.write { [target] transaction in
        try WriterPackPins.pin(pack, options: options, attempt: id, novel: target.novel, at: now, in: transaction.database)
      }
    } catch {
      throw .store(error)
    }
  }
}

extension JobServices {
  /// The one way a chapter call leaves the engine, in a job step or not: the novel's minor names are read at each call, so an age or name changed since the
  /// last one holds from this one (G19), and that one read is behind the input screen, the request guard and the output screen alike.
  private func sending<Result>(
    _ route: ChapterCallRoute, _ send: (TaskRouter, HardLineLexicon) async throws(ChapterCallFailure) -> Result
  ) async throws(JobStepCallError) -> Result {
    let lexicon: HardLineLexicon
    do {
      lexicon = try await hardLines.lexicon(for: route.novel, in: store)
    } catch {
      throw .engine(.store(error))
    }
    let router = await self.router { route in RequestGuard.hardLine(for: route, lexicon: lexicon)?.modelRequestGuard }
    do {
      return try await send(router, lexicon)
    } catch {
      throw .call(error)
    }
  }

  func call(
    _ route: ChapterCallRoute, pace: Pace, thinksDeeper: Bool = false, screening input: OrderedJSONObject, sections: [ContextSection] = [],
    request: (RoutedCall) -> ModelRequest, name: String, schema: JSONValue, review: StructuredReview = .none, observer: (StructuredStreamEvent) -> Void = { _ in }
  ) async throws(JobStepCallError) -> StructuredResult {
    try await sending(route) { router, lexicon throws(ChapterCallFailure) in
      try await route.run(
        router, pace: pace, thinksDeeper: thinksDeeper, consent: consent, screening: input, sections: sections, lexicon: lexicon, request: request, name: name,
        schema: schema, review: review, observer: observer)
    }
  }

  func callText(
    _ route: ChapterCallRoute, pace: Pace, thinksDeeper: Bool = false, screening input: OrderedJSONObject, sections: [ContextSection] = [],
    request: (RoutedCall) -> ModelRequest
  ) async throws(JobStepCallError) -> ChapterTextResult {
    try await sending(route) { router, lexicon throws(ChapterCallFailure) in
      try await route.runText(
        router, pace: pace, thinksDeeper: thinksDeeper, consent: consent, screening: input, sections: sections, lexicon: lexicon, request: request)
    }
  }
}

enum JobStepCallError: ShadowError {
  case engine(JobEngineError)
  case call(ChapterCallFailure)

  var code: String {
    switch self {
    case .engine(let error): error.code
    case .call(let failure): failure.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .engine(let error): error.errorDescription
    case .call(let failure): failure.errorDescription
    }
  }
}

/// Runs a `JobStep` for the runner with the begin hook set, so every stream the step opens, repair retries included, writes its call id on the attempt in
/// the transaction that begins the call, and the output hook, so the run's progress counts every stream's tokens.
struct EngineStep: PipelineStep {
  let step: any JobStep
  let version: Int
  let course: PipelineCourse?
  let services: JobServices

  func run(_ input: JSONValue, in context: AttemptStepContext) async throws -> AttemptStepOutput {
    guard let target = NovelJobTarget(context.job.request.key) else { throw JobEngineError.notANovelJob(context.job.ref) }
    guard let pins = JobPins(json: context.start.pinned), pins.pipeline == version else {
      throw JobEngineError.pipelineChanged(running: version, pinned: JobPins.pipelineVersion(in: context.start.pinned))
    }
    let stepContext = JobStepContext(attempt: context, target: target, pins: pins, services: services)
    let hook: ModelCallBeginHook = { call, transaction in try context.recordCall(call, in: &transaction) }
    let progress = services.progress
    progress.enter(context.attempt, step: context.step, outlook: await services.outlook(of: context.step.name, in: course))
    return try await ModelCallHooks.$begin.withValue(hook) {
      try await ModelCallHooks.$output.withValue(progress.observer(for: context.attempt)) { try await step.run(input, in: stepContext) }
    }
  }
}

/// Each novel's hard-line lexicon, rebuilt when the minor names its characters give change.
final class NovelHardLines: Sendable {
  private let cache = Mutex<[UUID: (names: [String], lexicon: HardLineLexicon)]>([:])

  func lexicon(for novel: UUID, in store: VaultStore) async throws(StoreError) -> HardLineLexicon {
    let names = try await store.read { transaction in minorNames(in: try EntityRecord.listing(novel: novel, in: transaction).live) }
    return cache.withLock { cache in
      if let cached = cache[novel], cached.names == names { return cached.lexicon }
      let lexicon = HardLineLexicon.standard.adding(minorNames: names)
      cache[novel] = (names, lexicon)
      return lexicon
    }
  }
}
