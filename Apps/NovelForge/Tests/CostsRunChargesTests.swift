import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("Run charges")
struct CostsRunChargesTests {
  private struct World {
    let store: VaultStore
    let novel: UUID

    static func make() async throws -> World {
      let store = try NovelForgeStore.openInMemory()
      let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
      return World(store: store, novel: novel)
    }

    func job(run: Int) async throws -> (job: EntityRef, attempts: [AttemptID]) {
      let key = try JobKey(scope: NovelJobAddress.scope(of: novel), kind: NovelJobKind.generate.rawValue, target: NovelJobAddress.target(chapter: 1), fingerprint: "f", run: run)
      let replica = store.replica
      _ = try await store.write { transaction in try JobRecords.request(JobRequest(key: key, payload: .null, replica: replica), in: &transaction) }
      return (key.ref, [])
    }

    func attempt(_ job: EntityRef, call: UUID, priced nanoUSD: Int64?, recording: Bool = true) async throws {
      let replica = store.replica
      let id = try AttemptID(UUID.v7())
      let start = ModelCallStart(id: call, provider: "api.example.com", model: "model-a", task: .chat, pace: .steady, startedMillis: 1_800_000_000_000)
      _ = try await store.write { transaction in
        if recording { try Ledger.begin(start, in: &transaction) }
        if recording, let nanoUSD {
          let events: [ModelEvent] = [
            .started(requestID: "r", generationID: "g"),
            .finished(usage: TokenUsage(input: 1_500, output: 500), reportedCost: Cost(nanoUSD: nanoUSD), stop: .endTurn),
          ]
          _ = try Ledger.finish(start, events: events, endedWith: nil, catalog: nil, in: &transaction)
        }
        _ = try AttemptRecords.start(
          id, AttemptStart(job: job, replica: replica, started: LeaseInstant(millis: 1_800_000_000_000, source: .device), byHand: false, pinned: .null), step: nil,
          in: &transaction)
        _ = try AttemptRecords.recordCall(call, attempt: id, by: replica, in: &transaction)
      }
    }

    func charges() async throws -> ChapterRunCharges {
      try await store.load(ChapterRunCharges.self, ChapterRunChargesQuery(novel: novel, chapter: 1))
    }
  }

  @Test func shouldSumAChaptersCostAcrossItsAttempts() async throws {
    let world = try await World.make()
    let first = try await world.job(run: 1).job
    let second = try await world.job(run: 2).job
    try await world.attempt(first, call: UUID(), priced: 40_000_000)
    try await world.attempt(first, call: UUID(), priced: 20_000_000)
    try await world.attempt(second, call: UUID(), priced: 10_000_000)

    guard case .runs(let runs, let total) = RunChargesDisplay.state(runs: try await world.charges().runs, total: try await world.charges().total) else {
      Issue.record("expected runs")
      return
    }
    #expect(runs.map(\.run) == [2, 1])
    #expect(runs.map { RunChargesDisplay.amount($0.cost) } == ["$0.010", "$0.060"])
    #expect(RunChargesDisplay.amount(total) == "$0.070")
    #expect(RunChargesDisplay.detail(total) == "3 calls · 6k tokens")
  }

  @Test func shouldCountACallTwoAttemptsNameOnce() async throws {
    let world = try await World.make()
    let job = try await world.job(run: 1).job
    let call = UUID()
    try await world.attempt(job, call: call, priced: 40_000_000)
    try await world.attempt(job, call: call, priced: nil, recording: false)

    let charges = try await world.charges()
    let run = try #require(charges.runs.value?.first?.cost)
    #expect(run.calls == 1 && RunChargesDisplay.amount(run) == "$0.040")
    let total = try #require(charges.total.value)
    #expect(total.calls == 1 && RunChargesDisplay.amount(total) == "$0.040")
  }

  @Test func shouldMarkAFigureThatIncludesAnEstimate() {
    #expect(RunChargesDisplay.amount(Cost(nanoUSD: 40_000_000), estimated: Cost(nanoUSD: 1), pending: false) == "$0.040*")
    #expect(RunChargesDisplay.amount(Cost(nanoUSD: 40_000_000), estimated: .zero, pending: false) == "$0.040")
    #expect(RunChargesDisplay.amount(Cost(nanoUSD: 40_000_000), estimated: Cost(nanoUSD: 1), pending: true) == "cost pending")
  }

  @Test func shouldShowAnUnpricedCallAsPendingNeverAsZero() async throws {
    let world = try await World.make()
    let job = try await world.job(run: 1).job
    try await world.attempt(job, call: UUID(), priced: 40_000_000)
    try await world.attempt(job, call: UUID(), priced: nil)

    let charges = try await world.charges()
    let total = try #require(charges.total.value)
    #expect(RunChargesDisplay.amount(total) == "cost pending")
    #expect(RunChargesDisplay.amount(try #require(charges.runs.value?.first?.cost)) == "cost pending")
  }

  @Test func shouldShowAJobWithNoCallsAsNothingSpent() async throws {
    let world = try await World.make()
    _ = try await world.job(run: 1)

    let charges = try await world.charges()
    let cost = try #require(charges.runs.value?.first?.cost)
    #expect(RunChargesDisplay.amount(cost) == "$0.00")
    #expect(RunChargesDisplay.detail(cost) == "0 calls")
  }

  @Test func shouldReadUnavailableWhenAFigureCannotBeRead() {
    #expect(RunChargesDisplay.state(runs: .unavailable([]), total: .available(.zero)) == .unavailable)
    #expect(RunChargesDisplay.state(runs: .available([]), total: .unavailable([])) == .unavailable)
    #expect(RunChargesDisplay.state(runs: .available([]), total: .available(.zero)) == .empty)
  }

  @Test func shouldKeepTokenCountsCompactAsTheReferenceDoes() {
    #expect(RunChargesDisplay.tokens(TokenUsage(input: 900, output: 99)) == "999")
    #expect(RunChargesDisplay.tokens(TokenUsage(input: 1_000, output: 0)) == "1k")
    #expect(RunChargesDisplay.tokens(TokenUsage(input: 12_300, output: 0)) == "12.3k")
    #expect(RunChargesDisplay.tokens(TokenUsage(input: 250_400, output: 0)) == "250k")
    #expect(RunChargesDisplay.tokens(TokenUsage(input: 2_500_000, output: 0)) == "2.5M")
  }
}
