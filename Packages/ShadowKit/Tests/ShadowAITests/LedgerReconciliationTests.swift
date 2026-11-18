import Foundation
import ShadowCore
import ShadowNetworking
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowAI

@Suite("Ledger reconciliation", .timeLimit(.minutes(1)))
struct LedgerReconciliationTests {
  private static let host = "openrouter.ai"
  private static let now = Date(timeIntervalSince1970: 1_700_100_000)

  private final class Sleeps: Sendable {
    private let recorded = Mutex<[Duration]>([])

    var values: [Duration] { recorded.withLock { $0 } }

    func record(_ duration: Duration) {
      recorded.withLock { $0.append(duration) }
    }
  }

  private static func cost(_ text: String) -> String { "{\"data\":{\"total_cost\":\(text)}}" }

  private static func transport(_ answers: [String: (Int, String)]) -> StubHTTPTransport {
    StubHTTPTransport { request in
      let id = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
      let (status, body) = answers[id] ?? (404, "{}")
      return try StubHTTPTransport.response(to: request, statusCode: status, data: Data(body.utf8))
    }
  }

  private static func lookup(_ transport: StubHTTPTransport) throws -> OpenRouterGenerationLookup {
    let credential = try makeCredential(OpenRouterFixtures.origin, secret: OpenRouterFixtures.secret)
    return OpenRouterGenerationLookup(credential: { () async throws(ModelError) in credential }, transport: transport)
  }

  private static func pending(_ id: UUID = UUID(), generation: String?, outcome: LedgerOutcome = .finished, startedMillis: Int64 = 1_700_000_000_000) -> ModelCallEntry {
    LedgerFixture.entry(id: id, provider: host, startedMillis: startedMillis, generationID: generation, outcome: outcome)
  }

  private static func reconcile(
    _ store: VaultStore, _ transport: StubHTTPTransport, policy: ReconciliationPolicy = .init(), sleeps: Sleeps = Sleeps()
  ) async throws -> ReconciliationReport {
    try await Ledger.reconcilePending(in: store, using: try lookup(transport), policy: policy, now: { now }, sleep: { sleeps.record($0) })
  }

  @Test("should write the reported cost of a pending entry and leave it reported")
  func reconcilesPending() async throws {
    let store = try LedgerFixture.store()
    let entry = Self.pending(generation: "gen-1")
    try await LedgerFixture.open(entry, in: store)
    let report = try await Self.reconcile(store, Self.transport(["gen-1": (200, Self.cost("\"0.000123456\""))]))
    #expect(report.reconciled == [entry.id])
    let stored = try #require(try await LedgerFixture.entries(store).first)
    #expect(stored.cost == Cost(nanoUSD: 123_456))
    #expect(stored.costSource == .reported)
  }

  @Test("should look up each entry once across two runs and keep the first reported figure")
  func idempotentAcrossRuns() async throws {
    let store = try LedgerFixture.store()
    let entry = Self.pending(generation: "gen-1")
    try await LedgerFixture.open(entry, in: store)
    let transport = Self.transport(["gen-1": (200, Self.cost("0.25"))])
    _ = try await Self.reconcile(store, transport)
    let second = try await Self.reconcile(store, Self.transport(["gen-1": (200, Self.cost("9"))]))
    #expect(second.reconciled.isEmpty)
    #expect(transport.requests.count == 1)
    #expect(try await LedgerFixture.entries(store).first?.cost == Cost(nanoUSD: 250_000_000))
  }

  @Test("should keep the first figure when a racing reconcile writes a different one")
  func firstWriterWins() async throws {
    let store = try LedgerFixture.store()
    let entry = Self.pending(generation: "gen-1")
    try await LedgerFixture.open(entry, in: store)
    try await LedgerFixture.reconcile(entry.id, Cost(nanoUSD: 7), in: store)
    try await LedgerFixture.reconcile(entry.id, Cost(nanoUSD: 99), in: store)
    #expect(try await LedgerFixture.entries(store).first?.cost == Cost(nanoUSD: 7))
  }

  @Test("should never look up an entry without a generation id, a settled entry or another provider's entry")
  func skipsIneligible() async throws {
    let store = try LedgerFixture.store()
    try await LedgerFixture.open(Self.pending(generation: nil), in: store)
    try await LedgerFixture.open(LedgerFixture.entry(provider: "api.anthropic.com", generationID: "gen-other", outcome: .finished), in: store)
    let settled = Self.pending(generation: "gen-settled")
    try await LedgerFixture.open(settled, in: store)
    try await LedgerFixture.reconcile(settled.id, Cost(nanoUSD: 5), in: store)
    let computed = LedgerFixture.entry(provider: Self.host, generationID: "gen-computed", outcome: .finished, cost: Cost(nanoUSD: 3), costSource: .computed)
    try await LedgerFixture.open(computed, in: store)
    let transport = Self.transport([:])
    let report = try await Self.reconcile(store, transport)
    #expect(transport.requests.isEmpty)
    #expect(report == ReconciliationReport())
  }

  @Test("should reconcile every eligible entry when an older entry has no generation id")
  func idlessEntryDoesNotDropOthers() async throws {
    let store = try LedgerFixture.store()
    try await LedgerFixture.open(Self.pending(generation: nil, startedMillis: 1_699_000_000_000), in: store)
    let first = Self.pending(generation: "gen-1", startedMillis: 1_700_000_000_000)
    let second = Self.pending(generation: "gen-2", startedMillis: 1_700_000_000_001)
    try await LedgerFixture.open(first, in: store)
    try await LedgerFixture.open(second, in: store)
    let report = try await Self.reconcile(store, Self.transport(["gen-1": (200, Self.cost("1")), "gen-2": (200, Self.cost("2"))]), policy: ReconciliationPolicy(maxConcurrent: 1))
    #expect(Set(report.reconciled) == [first.id, second.id])
  }

  @Test("should leave a call that is still within the grace period alone and look up an old unfinished call")
  func startedGrace() async throws {
    let store = try LedgerFixture.store()
    let nowMillis = Int64(Self.now.timeIntervalSince1970 * 1_000)
    let fresh = Self.pending(generation: "gen-fresh", outcome: .started, startedMillis: nowMillis - 1_000)
    let stale = Self.pending(generation: "gen-stale", outcome: .started, startedMillis: nowMillis - 3_600_000)
    try await LedgerFixture.open(fresh, in: store)
    try await LedgerFixture.open(stale, in: store)
    let report = try await Self.reconcile(store, Self.transport(["gen-fresh": (200, Self.cost("1")), "gen-stale": (200, Self.cost("2"))]))
    #expect(report.reconciled == [stale.id])
  }

  @Test("should keep a not-ready entry pending after the attempt limit with exponential backoff")
  func notReadyStaysPending() async throws {
    let store = try LedgerFixture.store()
    let entry = Self.pending(generation: "gen-1")
    try await LedgerFixture.open(entry, in: store)
    let transport = Self.transport([:])
    let sleeps = Sleeps()
    let policy = ReconciliationPolicy(maxAttempts: 3, backoff: .seconds(2), maxBackoff: .seconds(30))
    let report = try await Self.reconcile(store, transport, policy: policy, sleeps: sleeps)
    #expect(transport.requests.count == 3)
    #expect(sleeps.values == [.seconds(2), .seconds(4)])
    #expect(report.stillPending == [entry.id: .notReady])
    let stored = try #require(try await LedgerFixture.entries(store).first)
    #expect(stored.costSource == .pending)
    #expect(stored.cost == nil)
  }

  @Test("should reconcile an entry that becomes ready on a later attempt")
  func becomesReady() async throws {
    let store = try LedgerFixture.store()
    let entry = Self.pending(generation: "gen-1")
    try await LedgerFixture.open(entry, in: store)
    let calls = RunCounter()
    let transport = StubHTTPTransport { request in
      calls.increment()
      return try StubHTTPTransport.response(to: request, statusCode: calls.value < 3 ? 404 : 200, data: Data(Self.cost("0.5").utf8))
    }
    let report = try await Self.reconcile(store, transport)
    #expect(report.reconciled == [entry.id])
    #expect(calls.value == 3)
  }

  @Test("should stop the run on an authentication failure and leave every entry pending")
  func authenticationStopsRun() async throws {
    let store = try LedgerFixture.store()
    for index in 0..<6 { try await LedgerFixture.open(Self.pending(generation: "gen-\(index)", startedMillis: 1_700_000_000_000 + Int64(index)), in: store) }
    let transport = StubHTTPTransport(statusCode: 401, json: "{}")
    let report = try await Self.reconcile(store, transport, policy: ReconciliationPolicy(maxConcurrent: 1))
    #expect(report.stoppedByAuthentication)
    #expect(transport.requests.count == 1)
    #expect(try await LedgerFixture.entries(store).allSatisfy { $0.costSource == .pending })
  }

  @Test("should not retry a malformed response")
  func malformedNotRetried() async throws {
    let store = try LedgerFixture.store()
    let entry = Self.pending(generation: "gen-1")
    try await LedgerFixture.open(entry, in: store)
    let transport = Self.transport(["gen-1": (200, "garbage")])
    let report = try await Self.reconcile(store, transport)
    #expect(transport.requests.count == 1)
    #expect(report.stillPending == [entry.id: .malformed])
  }

  @Test("should look up at most the per-run cap, oldest first, and report the rest as deferred")
  func perRunCap() async throws {
    let store = try LedgerFixture.store()
    var ids: [UUID] = []
    for index in 0..<5 {
      let entry = Self.pending(generation: "gen-\(index)", startedMillis: 1_700_000_000_000 + Int64(index))
      ids.append(entry.id)
      try await LedgerFixture.open(entry, in: store)
    }
    let answers = Dictionary(uniqueKeysWithValues: (0..<5).map { ("gen-\($0)", (200, Self.cost("1"))) })
    let transport = Self.transport(answers)
    let report = try await Self.reconcile(store, transport, policy: ReconciliationPolicy(maxEntries: 2))
    #expect(Set(report.reconciled) == Set(ids.prefix(2)))
    #expect(report.deferred == 3)
    #expect(transport.requests.count == 2)
  }

  @Test("should bound the number of lookups in flight")
  func boundedConcurrency() async throws {
    let store = try LedgerFixture.store()
    for index in 0..<8 { try await LedgerFixture.open(Self.pending(generation: "gen-\(index)", startedMillis: 1_700_000_000_000 + Int64(index)), in: store) }
    let active = Mutex((current: 0, peak: 0))
    let transport = StubHTTPTransport { request in
      active.withLock { state in
        state.current += 1
        state.peak = max(state.peak, state.current)
      }
      try await Task.sleep(for: .milliseconds(20))
      active.withLock { $0.current -= 1 }
      return try StubHTTPTransport.response(to: request, statusCode: 200, data: Data(Self.cost("1").utf8))
    }
    let report = try await Self.reconcile(store, transport, policy: ReconciliationPolicy(maxConcurrent: 3))
    #expect(report.reconciled.count == 8)
    #expect(active.withLock { $0.peak } <= 3)
  }

  @Test("should converge two replicas that reconcile the same entry to one reported cost")
  func twoReplicas() async throws {
    let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: LedgerFixture.registry))
    let entry = Self.pending(generation: "gen-1")
    try await replicas.write(0) { transaction in try Ledger.open(entry, in: &transaction) }
    try await replicas.settle()
    let first = try await Self.reconcile(await replicas.store(0), Self.transport(["gen-1": (200, Self.cost("0.5"))]))
    let second = try await Self.reconcile(await replicas.store(1), Self.transport(["gen-1": (200, Self.cost("0.5"))]))
    #expect(first.reconciled == [entry.id])
    #expect(second.reconciled == [entry.id])
    try await replicas.settle()
    let costs = try await [replicas.store(0), replicas.store(1)].asyncMap { try await LedgerFixture.entries($0).first?.cost }
    #expect(costs == [Cost(nanoUSD: 500_000_000), Cost(nanoUSD: 500_000_000)])
  }

  @Test("should never move a reported entry back to pending when a later close arrives")
  func monotone() async throws {
    let store = try LedgerFixture.store()
    let entry = Self.pending(generation: "gen-1", outcome: .started)
    try await LedgerFixture.open(entry, in: store)
    _ = try await Self.reconcile(store, Self.transport(["gen-1": (200, Self.cost("0.5"))]), policy: ReconciliationPolicy(startedGrace: .zero))
    try await LedgerFixture.close(entry.id, .failed, in: store)
    let stored = try #require(try await LedgerFixture.entries(store).first)
    #expect(stored.costSource == .reported)
    #expect(stored.cost == Cost(nanoUSD: 500_000_000))
  }
}

extension Sequence where Element: Sendable {
  fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var result: [T] = []
    for element in self { result.append(try await transform(element)) }
    return result
  }
}
