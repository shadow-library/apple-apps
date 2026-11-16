import Foundation
import Testing

@testable import ShadowAI

@Suite("ModelCallAccounting")
struct LedgerAccountingTests {
  struct AttemptCase: CustomTestStringConvertible, Sendable {
    let name: String
    let events: [ModelEvent]
    let error: ModelError?
    let expected: [ModelCallAttempt]
    var testDescription: String { name }
  }

  private static let usage = TokenUsage(input: 100, output: 20)
  private static let finished = ModelEvent.finished(usage: usage, reportedCost: nil, stop: .endTurn)

  private static func retrying(_ attempt: Int, request: String?, generation: String?) -> ModelEvent {
    .retrying(attempt: attempt, delay: .seconds(1), cause: .server(status: 500), requestID: request, generationID: generation)
  }

  private static func attempt(
    _ request: String?, gen generation: String? = nil, _ outcome: LedgerOutcome, usage: TokenUsage = .zero, cost: Cost? = nil
  ) -> ModelCallAttempt {
    ModelCallAttempt(requestID: request, generationID: generation, outcome: outcome, usage: usage, reportedCost: cost)
  }

  static let attemptCases: [AttemptCase] = [
    AttemptCase(
      name: "plain success", events: [.started(requestID: "r1", generationID: nil), .textDelta("hi"), finished], error: nil,
      expected: [attempt("r1", .finished, usage: usage)]),
    AttemptCase(
      name: "refusal is a finished attempt with usage",
      events: [.started(requestID: "r1", generationID: "g1"), .finished(usage: usage, reportedCost: nil, stop: .refusal(category: "safety"))], error: nil,
      expected: [attempt("r1", gen: "g1", .finished, usage: usage)]),
    AttemptCase(
      name: "success after two retried attempts, one with ids and one without",
      events: [
        .started(requestID: "r1", generationID: "g1"), retrying(1, request: "r1", generation: "g1"), retrying(2, request: nil, generation: nil),
        .started(requestID: "r3", generationID: nil), .textDelta("ok"), finished,
      ], error: nil,
      expected: [attempt("r1", gen: "g1", .failed), attempt("r3", .finished, usage: usage)]),
    AttemptCase(
      name: "terminal error after started", events: [.started(requestID: "r1", generationID: nil)], error: .server(status: 500),
      expected: [attempt("r1", .failed)]),
    AttemptCase(name: "error before any event", events: [], error: .authentication, expected: []),
    AttemptCase(
      name: "cancellation after text", events: [.started(requestID: "r1", generationID: "g1"), .textDelta("par")], error: .cancelled,
      expected: [attempt("r1", gen: "g1", .cancelled)]),
    AttemptCase(
      name: "provider reported cost",
      events: [.started(requestID: "r1", generationID: "g1"), .finished(usage: usage, reportedCost: Cost(nanoUSD: 321), stop: .endTurn)], error: nil,
      expected: [attempt("r1", gen: "g1", .finished, usage: usage, cost: Cost(nanoUSD: 321))]),
    AttemptCase(
      name: "started without ids then an error is a failed attempt", events: [.started(requestID: nil, generationID: nil)], error: .transport(.timedOut),
      expected: [attempt(nil, .failed)]),
    AttemptCase(
      name: "finished with zero usage and no ids is still finished", events: [.finished(usage: .zero, reportedCost: nil, stop: .endTurn)], error: nil,
      expected: [attempt(nil, .finished)]),
    AttemptCase(
      name: "cancellation after text without ids is cancelled", events: [.started(requestID: nil, generationID: nil), .textDelta("par")], error: .cancelled,
      expected: [attempt(nil, .cancelled)]),
    AttemptCase(
      name: "an abandoned attempt sharing the final generation id is one billed attempt",
      events: [retrying(1, request: "r1", generation: "g1"), .started(requestID: "r2", generationID: "g1"), finished], error: nil,
      expected: [attempt("r2", gen: "g1", .finished, usage: usage)]),
    AttemptCase(
      name: "abandoned attempts sharing a generation id are one, distinct ones are kept",
      events: [
        retrying(1, request: "r1", generation: "g1"), retrying(2, request: "r2", generation: "g1"), retrying(3, request: "r3", generation: "g2"),
        .started(requestID: "r4", generationID: "g3"), finished,
      ], error: nil,
      expected: [attempt("r1", gen: "g1", .failed), attempt("r3", gen: "g2", .failed), attempt("r4", gen: "g3", .finished, usage: usage)]),
    AttemptCase(
      name: "text without a started event is still an attempt when it carries usage", events: [.textDelta("x"), finished], error: nil,
      expected: [attempt(nil, .finished, usage: usage)]),
    AttemptCase(
      name: "only retrying attempts with ids before an error", events: [retrying(1, request: "r1", generation: nil)], error: .server(status: 503),
      expected: [attempt("r1", .failed)]),
    AttemptCase(
      name: "retrying without ids then an error before any event records nothing", events: [retrying(1, request: nil, generation: nil)], error: .server(status: 503),
      expected: []),
    AttemptCase(
      name: "a stream that ends without finished or error is failed", events: [.started(requestID: "r1", generationID: nil), .textDelta("x")], error: nil,
      expected: [attempt("r1", .failed)]),
    AttemptCase(
      name: "retries then cancellation",
      events: [retrying(1, request: "r1", generation: "g1"), .started(requestID: "r2", generationID: "g2")], error: .cancelled,
      expected: [attempt("r1", gen: "g1", .failed), attempt("r2", gen: "g2", .cancelled)]),
  ]

  @Test("should turn one request's events into attempts", arguments: attemptCases)
  func turnsEventsIntoAttempts(_ item: AttemptCase) {
    #expect(ModelCallAccounting.attempts(from: item.events, endedWith: item.error) == item.expected)
  }

  @Test("should record a reported cost even when an attempt has no ids and no usage")
  func keepsReportedCostOnly() {
    let events: [ModelEvent] = [.finished(usage: .zero, reportedCost: Cost(nanoUSD: 9), stop: .endTurn)]
    #expect(ModelCallAccounting.attempts(from: events, endedWith: nil) == [Self.attempt(nil, .finished, cost: Cost(nanoUSD: 9))])
  }

  private static let longTier = ModelPricing(
    input: Cost(nanoUSD: 6_000_000_000), output: Cost(nanoUSD: 22_000_000_000), cacheRead: Cost(nanoUSD: 600_000_000), cacheWriteShort: Cost(nanoUSD: 7_500_000_000),
    cacheWriteLong: Cost(nanoUSD: 12_000_000_000))

  private static let catalog: ModelCatalog = {
    var tiered = CatalogFixtures.model("tiered")
    tiered.longPrompt = CatalogLongPromptPricing(aboveTokens: 200_000, pricing: longTier)
    return CatalogFixtures.catalog(models: [CatalogFixtures.model("flat"), tiered])
  }()

  struct CostCase: CustomTestStringConvertible, Sendable {
    let name: String
    let attempt: ModelCallAttempt
    let model: String
    let catalog: ModelCatalog?
    let cost: Cost?
    let source: LedgerCostSource
    var testDescription: String { name }
  }

  static let costCases: [CostCase] = [
    CostCase(
      name: "reported cost wins over the catalog", attempt: attempt("r", gen: "g", .finished, usage: usage, cost: Cost(nanoUSD: 5)), model: "flat", catalog: catalog,
      cost: Cost(nanoUSD: 5), source: .reported),
    CostCase(
      name: "reported cost without a catalog", attempt: attempt("r", gen: "g", .finished, usage: usage, cost: Cost(nanoUSD: 5)), model: "flat", catalog: nil,
      cost: Cost(nanoUSD: 5), source: .reported),
    CostCase(
      name: "known model is computed", attempt: attempt("r", .finished, usage: TokenUsage(input: 1_000_000, output: 1_000_000)), model: "flat", catalog: catalog,
      cost: Cost(nanoUSD: 18_000_000_000), source: .computed),
    CostCase(
      name: "long-prompt model at its threshold uses the base tier", attempt: attempt("r", .finished, usage: TokenUsage(input: 200_000)), model: "tiered", catalog: catalog,
      cost: Cost(nanoUSD: 600_000_000), source: .computed),
    CostCase(
      name: "long-prompt model above its threshold uses the long tier", attempt: attempt("r", .finished, usage: TokenUsage(input: 200_001)), model: "tiered",
      catalog: catalog, cost: Cost(nanoUSD: 1_200_006_000), source: .computed),
    CostCase(
      name: "unknown model is pending", attempt: attempt("r", .finished, usage: usage), model: "missing", catalog: catalog, cost: nil, source: .pending),
    CostCase(name: "no catalog is pending", attempt: attempt("r", .finished, usage: usage), model: "flat", catalog: nil, cost: nil, source: .pending),
    CostCase(
      name: "failed attempt with a generation id is pending", attempt: attempt("r", gen: "g", .failed), model: "flat", catalog: catalog, cost: nil, source: .pending),
    CostCase(
      name: "cancelled attempt with a generation id is pending", attempt: attempt("r", gen: "g", .cancelled), model: "flat", catalog: catalog, cost: nil, source: .pending),
    CostCase(
      name: "failed attempt without a generation id costs zero", attempt: attempt("r", .failed), model: "flat", catalog: catalog, cost: .zero, source: .computed),
    CostCase(
      name: "cancelled attempt without a generation id costs zero", attempt: attempt("r", .cancelled), model: "missing", catalog: nil, cost: .zero, source: .computed),
    CostCase(
      name: "reported cost on a failed attempt is kept", attempt: attempt("r", gen: "g", .failed, cost: Cost(nanoUSD: 8)), model: "flat", catalog: nil, cost: Cost(nanoUSD: 8),
      source: .reported),
  ]

  @Test("should price one attempt", arguments: costCases)
  func pricesAnAttempt(_ item: CostCase) {
    let result = ModelCallAccounting.cost(for: item.attempt, model: item.model, catalog: item.catalog)
    #expect(result.cost == item.cost)
    #expect(result.source == item.source)
  }

  @Test("should price each attempt on its own usage so two long-prompt-sized halves stay on the base tier")
  func pricesAttemptsSeparately() {
    let half = TokenUsage(input: 150_000)
    let attempts = [Self.attempt("r1", .finished, usage: half), Self.attempt("r2", .finished, usage: half)]
    let costs = attempts.map { ModelCallAccounting.cost(for: $0, model: "tiered", catalog: Self.catalog).cost }
    #expect(costs == [Cost(nanoUSD: 450_000_000), Cost(nanoUSD: 450_000_000)])
  }
}
