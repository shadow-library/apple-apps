import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore
@testable import ShadowJobs

@Suite("Insight requests", TestTimeLimit.standard)
struct InsightRequestTests {
  private static let question = "why do I keep missing evening quests?"
  private static let questionID = UUID.v7()

  private func settled(_ due: InsightDue) async throws -> AttemptResult {
    let handle = try #require(due.handle, "expected a started attempt, got \(due.label)")
    return await handle.result
  }

  private func listing(_ harness: InsightHarness) async throws -> [InsightRequest] {
    try await InsightRequests.listing(in: harness.stores.main, at: LeaseClock(trusted: nil, device: harness.clock.function).now()).requests
  }

  @Test func shouldListAnAnsweredQuestionWithItsResultAndTheCostOfItsCalls() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    harness.provider.enqueueReply(InsightHarness.reply(), reportedCost: Cost(nanoUSD: 1_250_000))

    #expect(try await settled(try await harness.engine.ask(Self.question, id: Self.questionID)) == .settled(.succeeded))

    let request = try #require(try await listing(harness).first)
    #expect(request.kind == .adhoc && request.target == .question(Self.questionID) && request.question == Self.question)
    #expect(request.status == .succeeded && request.run == 1)
    #expect(request.cost == InsightCost(cost: Cost(nanoUSD: 1_250_000), pendingCalls: 0))
    #expect(try await harness.results().map(\.id) == [request.resultID])
    #expect(request.startedMillis != nil)
  }

  @Test func shouldAskAFailedQuestionAgainUnderItsNextRunAndKeepOnlyTheLatestInTheListing() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    harness.provider.enqueueReply(InsightHarness.reply(answer: "You are lazy about evenings."))
    let first = try await settled(try await harness.engine.ask(Self.question, id: Self.questionID))
    guard case .settled(.failed) = first else { throw MemoirFixtureError(description: "expected a blocked answer, got \(first)") }
    let failed = try #require(try await listing(harness).first)
    #expect(failed.status == .failed(code: "insight.guardrail_blocked"))
    #expect(try await harness.engine.ask(Self.question, id: Self.questionID).label == "failed:insight.guardrail_blocked")

    harness.provider.enqueueReply(InsightHarness.reply())
    #expect(try await settled(try await harness.engine.retry(job: failed.job)) == .settled(.succeeded))

    let requests = try await listing(harness)
    #expect(requests.count == 1)
    #expect(requests.first?.run == 2 && requests.first?.status == .succeeded)
    #expect(try await harness.results().map(\.question) == [Self.question])
    #expect(try await harness.engine.retry(job: try #require(requests.first).job).label == "succeeded")
    #expect(harness.provider.requests.count == 2)
    #expect(try await harness.commandCount() == 0)
  }

  @Test func shouldCancelARunningQuestionAndAskItAgainAfterwards() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    harness.provider.enqueue([.delay(.seconds(2))] + ScriptedModelProvider.reply(InsightHarness.reply()))
    let due = try await harness.engine.ask(Self.question, id: Self.questionID)
    let handle = try #require(due.handle)
    let job = handle.job

    let leases = LeaseClock(trusted: nil, device: harness.clock.function)
    let live = try await InsightRequests.listing(in: harness.stores.main, at: leases.now())
    let lease = try #require(try await harness.snapshot(job)?.attempts.first?.lease)
    #expect(live.requests.first?.status == .running)
    #expect(live.changesAt == Date(timeIntervalSince1970: Double(lease.expires) / 1000), "the listing changes when the live lease lapses")
    harness.clock.advance(seconds: Double(LeaseTerms.duration.components.seconds) + 1)
    let lapsed = try await InsightRequests.listing(in: harness.stores.main, at: leases.now())
    #expect(lapsed.requests.first?.status == .queued && lapsed.changesAt == nil)

    #expect(try await harness.engine.cancel(job: job) == .requested)
    #expect(await handle.result == .settled(.cancelled))
    #expect(try await listing(harness).first?.status == .cancelled)
    #expect(try await harness.results().isEmpty)

    harness.provider.enqueueReply(InsightHarness.reply())
    #expect(try await settled(try await harness.engine.retry(job: job)) == .settled(.succeeded))
    #expect(try await listing(harness).map(\.status) == [.succeeded])
  }

  @Test func shouldRefuseToCancelOrRetryAJobThatIsNotAnInsight() async throws {
    let harness = try InsightHarness()
    let request = JobRequest(
      key: try JobKey(scope: "elsewhere", kind: "other", target: "t", fingerprint: "f", run: 1), payload: ["question": "q"], replica: harness.stores.main.replica)
    _ = try await harness.stores.main.write { transaction in try JobRecords.request(request, in: &transaction) }
    let other = request.key.ref
    let refusesAsNotAnInsight = { (error: any Error) -> Bool in
      guard case InsightError.notAnInsightJob(let ref) = error else { return false }
      return ref == other
    }
    await #expect(performing: { _ = try await harness.engine.cancel(job: other) }, throws: refusesAsNotAnInsight)
    await #expect(performing: { _ = try await harness.engine.retry(job: other) }, throws: refusesAsNotAnInsight)
    #expect(try await harness.snapshot(other)?.job.cancel == JobCancel.none, "nothing was cancelled")
  }
}
