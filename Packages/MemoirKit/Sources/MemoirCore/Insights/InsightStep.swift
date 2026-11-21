import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText

struct InsightServices: Sendable {
  let stores: MemoirStores
  let assembler: InsightAssembler
  let router: InsightEngine.RouterSource
  let pace: Pace
  let now: @Sendable () -> LeaseInstant
}

/// What one model call returned, with what the assembly showed it, ready for the guardrails.
struct InsightCallResult: Sendable {
  let draft: InsightDraft
  let assembly: InsightAssembly
  let model: String
}

/// The only way an insight reaches a model: routed (the call's consent and the spend cap), the classes' consent read for the routed host before anything is
/// assembled and read again before sending, and every request ledgered on the attempt.
struct InsightStepContext: Sendable {
  static let assemblyLimit = 3

  let attempt: AttemptStepContext
  let services: InsightServices

  func call(question: String, today: LocalDate) async throws(InsightError) -> InsightCallResult {
    let call: RoutedCall
    do {
      call = try await services.router().prepare(TaskCall(task: .chat, pace: services.pace, consent: InsightConsent.call))
    } catch {
      throw .routing(error)
    }
    let assembly = try await settledAssembly(question: question, today: today, host: call.host)
    let request = call.request(
      system: [ContextSegment(text: InsightPrompt.system, endsStablePrefix: true)], messages: [.user(InsightPrompt.user(question: question, context: assembly.context))])
    let hook: ModelCallBeginHook = { [attempt] id, transaction in try attempt.recordCall(id, in: &transaction) }
    let outcome = await ModelCallHooks.$begin.withValue(hook) { () async -> Result<StructuredResult, StructuredError> in
      do throws(StructuredError) {
        return .success(try await call.structured(request, name: InsightPrompt.schemaName, schema: InsightPrompt.schema))
      } catch {
        return .failure(error)
      }
    }
    switch outcome {
    case .success(let result):
      let parsed: OrderedJSON
      do {
        parsed = try OrderedJSON(parsing: String(decoding: result.json, as: UTF8.self))
      } catch {
        throw .unusableAnswer
      }
      return InsightCallResult(draft: try InsightDraft(parsing: parsed), assembly: assembly, model: call.route.model)
    case .failure(.refused): throw .refused
    case .failure(.truncated): throw .truncated
    case .failure(.model(let error, _)): throw .model(code: error.code)
    case .failure(.invalid), .failure(.decoding): throw .unusableAnswer
    }
  }

  /// A class withdrawn while the context was gathered is gathered again without it; a class granted meanwhile waits for the next run.
  private func settledAssembly(question: String, today: LocalDate, host: String) async throws(InsightError) -> InsightAssembly {
    var consent = try await snapshot(host: host)
    for _ in 0..<Self.assemblyLimit {
      let assembly = try await services.assembler.assemble(question: question, consent: consent, today: today)
      let current = try await snapshot(host: host)
      if current.covers(assembly.consent) { return assembly }
      consent = current
    }
    throw .consentUnsettled
  }

  private func snapshot(host: String) async throws(InsightError) -> InsightConsentSnapshot {
    do {
      return try await services.stores.main.read { transaction in try InsightConsent.snapshot(provider: host, in: transaction) }
    } catch {
      throw .converting(error)
    }
  }
}

/// The insight pipeline's one step: a result already stored for the job ends it without a call; otherwise one call, the guardrails, and the result written
/// to the store of its class. It issues no command: a suggestion is an offer the owner takes by editing the quest.
// apps/memoir-server/src/modules/ai-worker/ai-executor.service.ts:111-170
struct InsightStep: PipelineStep {
  static let name = "answer"
  static let logger = Logger(category: "memoir.insights")

  let services: InsightServices

  func run(_ input: JSONValue, in context: AttemptStepContext) async throws -> AttemptStepOutput {
    let job = try InsightJob(context.job)
    if try await InsightResults.contains(job: job.ref, in: services.stores) { return AttemptStepOutput(state: .null, next: nil) }
    let now = services.now()
    let today: LocalDate
    switch job.target {
    case .night(let date): today = date
    case .question: today = LocalDate(daysSinceEpoch: Int(now.millis.quotient(dividingBy: 86_400_000))) ?? .latest
    }
    let result = try await InsightStepContext(attempt: context, services: services).call(question: job.question, today: today)
    let guarded = InsightGuardrails.apply(
      GuardrailInput(
        question: job.question, sensitiveSources: result.assembly.sensitiveSources, allowedQuestIDs: result.assembly.questIDs, draft: result.draft))
    let draft: InsightDraft
    switch guarded {
    case .blocked(let violations):
      Self.logger.notice("An insight was refused by the output guardrails violations=\(violations.map(\.rawValue).joined(separator: ","), privacy: .public)")
      throw InsightError.guardrailBlocked(violations)
    case .passed(let passed), .sanitized(let passed, _), .crisis(let passed):
      draft = passed
    }
    try await InsightResults.store(
      draft, of: job, assembly: result.assembly, model: result.model, at: now.millis, in: services.stores)
    return AttemptStepOutput(state: .null, next: nil)
  }
}

extension Int64 {
  fileprivate func quotient(dividingBy divisor: Int64) -> Int64 {
    self >= 0 ? self / divisor : (self - divisor + 1) / divisor
  }
}

/// Where insight results live: one kind per class, each in its class's store.
public enum InsightResults {
  public static func contains(job: EntityRef, in stores: MemoirStores) async throws(InsightError) -> Bool {
    let id = InsightRecord<GeneralMetric>.id(forJob: job)
    do {
      if try await stores.main.read({ transaction in try InsightRecord<GeneralMetric>.read(id: id, in: transaction) != .absent }) { return true }
      if try await stores.activity.read({ transaction in try InsightRecord<ActivityMetric>.read(id: id, in: transaction) != .absent }) { return true }
      return try await stores.restricted.read { transaction in try InsightRecord<HealthMetric>.read(id: id, in: transaction) != .absent }
    } catch {
      throw .converting(error)
    }
  }

  /// Every readable result in the three stores, newest first.
  public static func listing(in stores: MemoirStores) async throws(InsightError) -> [InsightResultEntry] {
    do {
      let general = try await stores.main.read { transaction in try entries(InsightRecord<GeneralMetric>.self, .general, transaction) }
      let activity = try await stores.activity.read { transaction in try entries(InsightRecord<ActivityMetric>.self, .activity, transaction) }
      let health = try await stores.restricted.read { transaction in try entries(InsightRecord<HealthMetric>.self, .health, transaction) }
      return (general + activity + health).sorted { ($0.createdMillis, $0.id.lowercasedString) > ($1.createdMillis, $1.id.lowercasedString) }
    } catch {
      throw .converting(error)
    }
  }

  /// The guardrails' draft as the owner reads it: only suggestions naming a quest of this vault by its id survive the typed form.
  static func store(
    _ draft: InsightDraft, of job: InsightJob, assembly: InsightAssembly, model: String, at millis: Int64, in stores: MemoirStores
  ) async throws(InsightError) {
    let fields = (
      id: InsightRecord<GeneralMetric>.id(forJob: job.ref), job: job.ref.key.rawValue, question: job.question, answer: draft.answer, patterns: draft.patterns,
      suggestions: draft.suggestions.compactMap(InsightSuggestion.init), note: draft.limitationNote,
      citations: assembly.dataClasses.map { StoredChoice<InsightReadClass>.known($0) }
    )
    func record<Class: MetricClass>(_: Class.Type) -> InsightRecord<Class> {
      InsightRecord(
        id: fields.id, job: fields.job, question: fields.question, answer: fields.answer, patterns: fields.patterns, suggestions: fields.suggestions,
        limitationNote: fields.note, citations: fields.citations, model: model, promptVersion: InsightPrompt.version, createdMillis: millis)
    }
    do {
      switch assembly.resultClass {
      case .general:
        let insight = record(GeneralMetric.self)
        try await stores.main.write { transaction in try insight.create(in: &transaction) }
      case .activity:
        let insight = record(ActivityMetric.self)
        try await stores.activity.write { transaction in try insight.create(in: &transaction) }
      case .health:
        let insight = record(HealthMetric.self)
        try await stores.restricted.write { transaction in try insight.create(in: &transaction) }
      }
    } catch {
      throw .converting(error)
    }
  }

  private static func entries<Class: MetricClass>(_: InsightRecord<Class>.Type, _ syncClass: SyncClass, _ transaction: ReadTransaction) throws(StoreError)
    -> [InsightResultEntry]
  {
    try InsightRecord<Class>.listing(in: transaction).entries.filter { !$0.isRemoved }.map { entry in
      let record = entry.record
      return InsightResultEntry(
        id: record.id, syncClass: syncClass, question: record.question, answer: record.answer, patterns: record.patterns, suggestions: record.suggestions,
        limitationNote: record.limitationNote, citations: record.citations, createdMillis: record.createdMillis)
    }
  }
}

/// A stored result read from whichever store holds it.
public struct InsightResultEntry: Sendable, Equatable {
  public let id: UUID
  public let syncClass: SyncClass
  public let question: String
  public let answer: String
  public let patterns: [String]
  public let suggestions: [InsightSuggestion]
  public let limitationNote: String?
  public let citations: [StoredChoice<InsightReadClass>]
  public let createdMillis: Int64
}
