import Foundation
import NovelForgeCore
import ShadowAI
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeEval

@Suite("Eval run", TestTimeLimit.standard)
struct EvalRunTests {
  @Test func shouldRunEveryPipelineAndMeasureTheFinalChapter() async throws {
    let (report, provider) = try await EvalScript.run()
    let outcomes = report.steps.map { "\($0.chapter) \($0.name.rawValue) \($0.outcome.text)" }
    #expect(
      outcomes == [
        "1 plan succeeded", "1 generate succeeded", "1 review succeeded", "1 finalize_review succeeded", "1 finalize succeeded", "1 refresh succeeded",
      ])
    #expect(provider.requests.count == 6 && provider.remainingCalls == 0)
    let chapter = try #require(report.chapters.first)
    #expect(report.chapters.count == 1 && chapter.status == "final" && chapter.approved && chapter.judge == "consistent" && chapter.body == EvalScript.body)
    #expect(report.passed && report.failOpen.holds && report.evaluationFailedRate.evaluationFailedCount == 0)
    #expect(report.metrics.contains(#""words":41"#) && report.metrics.contains(#""hookType":"turn""#))
  }

  @Test func shouldPrintAByteStableReport() async throws {
    let first = try await EvalScript.run().report.json.pretty
    let second = try await EvalScript.run().report.json.pretty
    #expect(first == second)
    #expect(first.hasPrefix("{\n  \"novel\": \"6f0c4d1e-0000-4000-8000-000000000e01\",\n  \"passed\": true,\n  \"steps\": [\n"))
    #expect(first.contains("\"metrics\": {\n    \"chapters\": [") && first.hasSuffix("}"))
  }

  @Test func shouldStopAtTheFirstFailingStepAndFailTheReport() async throws {
    let (report, provider) = try await EvalScript.run(calls: Array(EvalScript.calls.prefix(1)))
    #expect(report.steps.map(\.name) == [.plan, .generate])
    #expect(report.steps.last?.outcome.isFailure == true && !report.passed)
    #expect(report.chapters.isEmpty && provider.requests.count >= 1)
  }

  @Test func shouldMeasureTheChaptersAlreadyInAVaultWithoutAModel() async throws {
    let store = try NovelForgeStore.openInMemory()
    try await EvalFixture.seed(in: store)
    let report = try await EvalMeasurement.report(store: store, novel: EvalFixture.novel, steps: [], priorWindow: 10)
    #expect(report.steps.isEmpty && report.chapters.isEmpty && report.passed)
    #expect(report.json.pretty.contains("\"steps\": []") && report.json.pretty.contains("\"chapters\": []"))
  }

  @Test func shouldRefuseARealVaultWithoutAnExistingConsentAndWriteNone() async throws {
    let store = try NovelForgeStore.openInMemory()
    try await EvalFixture.seed(in: store)
    let provider = ScriptedModelProvider(calls: EvalScript.calls)
    let backend = try EvalScript.backend(provider)
    let runner = EvalRunner(store: store, backend: backend, consent: .require)
    await #expect(throws: EvalError.self) { try await runner.run(novel: EvalFixture.novel, chapters: 1) }
    await #expect(throws: EvalError.self) { try await backend.requireConsent(in: store) }
    #expect(provider.requests.isEmpty)
  }

  @Test func shouldRunARealVaultThatAlreadyHoldsTheConsent() async throws {
    let store = try NovelForgeStore.openInMemory()
    try await EvalFixture.seed(in: store)
    let backend = try EvalScript.backend(ScriptedModelProvider(calls: EvalScript.calls))
    try await backend.grantConsent(in: store)
    let report = try await EvalRunner(store: store, backend: backend, consent: .require).run(novel: EvalFixture.novel, chapters: 1)
    #expect(report.passed && report.steps.count == 6)
  }

  @Test func shouldStopAfterAFailedPlanCall() async throws {
    let (report, provider) = try await EvalScript.run(calls: [[.failure(.authentication)]])
    #expect(report.steps.map(\.name) == [.plan] && report.steps.first?.outcome.isFailure == true && !report.passed)
    #expect(provider.requests.count == 1)
  }

  @Test func shouldNotStartASecondChapterWhenTheFirstFailed() async throws {
    let (report, provider) = try await EvalScript.run(calls: Array(EvalScript.calls.prefix(1)), chapters: 2)
    #expect(report.steps.map(\.chapter).allSatisfy { $0 == 1 } && report.steps.last?.outcome.isFailure == true)
    #expect(report.steps.filter { $0.name == .plan }.count == 1 && provider.requests.count == 2)
  }

  @Test func shouldDropAnEmptyBodyAndCountItAsSkipped() async throws {
    let store = try NovelForgeStore.openInMemory()
    try await EvalFixture.seed(in: store)
    let novel = EvalFixture.novel
    try await store.write { transaction in
      _ = try DraftRecord(novel: novel, chapter: 1, content: DraftContent(body: "", source: .known(.handEdited))).create(in: &transaction)
      _ = try DraftRecord(novel: novel, chapter: 2, content: DraftContent(body: "Mara waits.", source: .known(.handEdited))).create(in: &transaction)
    }
    let loaded = try await NovelEvaluation.chapters(novel: novel, in: store)
    #expect(loaded.chapters.map(\.chapter) == [2] && loaded.skipped == [EvaluationSkip(chapter: 1, reason: "empty_body")])
    let report = try await EvalMeasurement.report(store: store, novel: novel, steps: [], priorWindow: 10)
    #expect(report.json.compact.contains(#""skipped":[{"chapter":1,"reason":"empty_body"}]"#))
  }
}
