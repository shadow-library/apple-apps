import Foundation
import NovelForgeCore
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

struct EvalRunner: Sendable {
  enum Consent: Sendable {
    case record
    case require
  }

  let store: VaultStore
  let backend: EvalBackend
  let consent: Consent

  func run(novel: UUID, chapters count: Int, priorWindow: Int = NovelEvaluation.defaultPriorWindow) async throws(EvalError) -> EvalReport {
    switch consent {
    case .record: try await backend.grantConsent(in: store)
    case .require: try await backend.requireConsent(in: store)
    }
    let engine = try makeEngine()
    var steps: [EvalStep] = []
    for _ in 0..<count where !steps.contains(where: \.outcome.isFailure) { await runChapter(engine: engine, novel: novel, into: &steps) }
    return try await EvalMeasurement.report(store: store, novel: novel, steps: steps, priorWindow: priorWindow)
  }

  private func makeEngine() throws(EvalError) -> JobEngine {
    let (store, backend) = (store, backend)
    do {
      return try JobEngine(
        store: store, router: { requestGuard in backend.router(store: store, requestGuard: requestGuard) }, consent: EvalBackend.consent, clock: LeaseClock(trusted: nil),
        ageGate: AgeGate(passed: false))
    } catch {
      throw .setup("The job engine could not start: \(error.code)")
    }
  }

  private func runChapter(engine: JobEngine, novel: UUID, into steps: inout [EvalStep]) async {
    let (chapter, planned) = await plan(engine, novel: novel)
    steps.append(EvalStep(chapter: chapter, name: .plan, outcome: planned))
    guard !planned.isFailure else { return }
    let stages: [(EvalStep.Name, () async -> EvalStep.Outcome)] = [
      (.generate, { await generate(engine, novel: novel, chapter: chapter) }),
      (.review, { await review(engine, novel: novel, chapter: chapter) }),
      (.finalizeReview, { await finalizeReview(engine, novel: novel, chapter: chapter) }),
      (.finalize, { await finalize(novel: novel, chapter: chapter) }),
      (.refresh, { await refresh(engine, novel: novel, chapter: chapter) }),
    ]
    for (name, stage) in stages {
      let outcome = await stage()
      steps.append(EvalStep(chapter: chapter, name: name, outcome: outcome))
      if outcome.isFailure { return }
    }
  }

  private func plan(_ engine: JobEngine, novel: UUID) async -> (chapter: Int, outcome: EvalStep.Outcome) {
    do {
      let receipt = try await engine.requestPlan(ChapterPlanJobRequest(novel: novel))
      let handle = try await engine.run(job: receipt.job.ref)
      let settled = Self.outcome(of: await handle.result)
      guard settled == .succeeded else { return (receipt.chapter, settled) }
      let applied = try await NovelEvaluation.applyPlanCard(of: receipt.job.ref, novel: novel, in: store, now: Date())
      return (receipt.chapter, applied ? .succeeded : .refused("plan_card_conflicted"))
    } catch {
      return (0, .refused(Self.code(error)))
    }
  }

  private func generate(_ engine: JobEngine, novel: UUID, chapter: Int) async -> EvalStep.Outcome {
    do {
      switch try await engine.generateChapter(novel: novel, chapter: chapter) {
      case .running(let handle): return Self.outcome(of: await handle.result)
      case .elsewhere: return .failed("running_elsewhere")
      }
    } catch {
      return .refused(Self.code(error))
    }
  }

  private func review(_ engine: JobEngine, novel: UUID, chapter: Int) async -> EvalStep.Outcome {
    do {
      switch try await engine.requestReview(novel: novel, chapter: chapter, kind: .judge) {
      case .reviewed: return .succeeded
      case .running(let handle): return Self.outcome(of: await handle.result)
      case .elsewhere: return .failed("running_elsewhere")
      }
    } catch {
      return .refused(Self.code(error))
    }
  }

  private func finalizeReview(_ engine: JobEngine, novel: UUID, chapter: Int) async -> EvalStep.Outcome {
    do {
      let ref = try DraftRecord.ref(novel: novel, chapter: chapter)
      let head = try await store.read { transaction in try DraftRecord.history(ref, in: transaction).history?.head }
      guard let head else { return .refused("draft_missing") }
      try await store.approveChapter(novel: novel, chapter: chapter, revision: head)
      guard let job = try await store.finalizeReviewJob(novel: novel, chapter: chapter) else { return .refused("finalize_review_missing") }
      let handle = try await engine.run(job: job)
      return Self.outcome(of: await handle.result)
    } catch {
      return .refused(Self.code(error))
    }
  }

  private func finalize(novel: UUID, chapter: Int) async -> EvalStep.Outcome {
    do {
      guard try await NovelEvaluation.chapters(novel: novel, in: store).chapters.first(where: { $0.chapter == chapter })?.status != "final" else { return .succeeded }
      try await store.keepRoutineFinalizeItems(novel: novel, chapter: chapter)
      try await store.write { transaction in try ChapterFinalize.finalize(novel: novel, chapter: chapter, in: &transaction) }
      return .succeeded
    } catch {
      return .refused(Self.code(error))
    }
  }

  private func refresh(_ engine: JobEngine, novel: UUID, chapter: Int) async -> EvalStep.Outcome {
    do {
      let key = try await engine.requestCanonRefresh(novel: novel, chapter: chapter)
      let handle = try await engine.run(job: key.ref)
      return Self.outcome(of: await handle.result)
    } catch {
      return .refused(Self.code(error))
    }
  }

  private static func outcome(of result: AttemptResult) -> EvalStep.Outcome {
    switch result {
    case .settled(.succeeded): .succeeded
    case .settled(.failed(let failure)): .failed(failure.code)
    case .settled(.stoodDown): .failed("stood_down")
    case .settled(.cancelled): .failed("cancelled")
    case .interrupted: .failed("interrupted")
    }
  }

  static func code(_ error: any Error) -> String {
    if let store = error as? StoreError, case .aborted(let cause) = store { return code(cause) }
    return (error as? any ShadowError)?.code ?? "unknown"
  }
}
