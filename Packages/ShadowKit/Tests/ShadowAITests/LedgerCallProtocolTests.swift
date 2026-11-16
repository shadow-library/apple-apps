import Foundation
import ShadowStore
import Testing

@testable import ShadowAI

@Suite("Ledger begin and finish", .timeLimit(.minutes(1)))
struct LedgerCallProtocolTests {
  private static let usage = TokenUsage(input: 100, output: 20)
  private static let catalog = CatalogFixtures.catalog(models: [CatalogFixtures.model("model-a")])

  private static func start(_ clock: LedgerTestClock = LedgerTestClock()) -> ModelCallStart {
    ModelCallStart(id: UUID(), provider: "API.Example.com", model: "model-a", task: .writing, pace: .steady, startedMillis: clock.millis)
  }

  private static func begin(_ call: ModelCallStart, in store: VaultStore) async throws {
    try await store.write { transaction in try Ledger.begin(call, in: &transaction) }
  }

  private static func finish(
    _ call: ModelCallStart, _ events: [ModelEvent], error: ModelError? = nil, catalog: ModelCatalog? = catalog, in store: VaultStore
  ) async throws -> [ModelCallEntry] {
    try await store.write { transaction in try Ledger.finish(call, events: events, endedWith: error, catalog: catalog, in: &transaction) }
  }

  private static func retrying(_ attempt: Int, request: String?, generation: String?) -> ModelEvent {
    .retrying(attempt: attempt, delay: .seconds(1), cause: .server(status: 500), requestID: request, generationID: generation)
  }

  private static let done = ModelEvent.finished(usage: usage, reportedCost: nil, stop: .endTurn)

  @Test("should show a begun call as one started entry with a pending cost")
  func begunIsStarted() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let entry = try #require(try await LedgerFixture.entries(store).first)
    #expect(entry.id == call.id)
    #expect(entry.outcome == .started)
    #expect(entry.costSource == .pending)
    #expect(entry.provider == "api.example.com")
  }

  @Test("should close the begun entry for a plain success")
  func plainSuccess() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let written = try await Self.finish(call, [.started(requestID: "r1", generationID: nil), .textDelta("hi"), Self.done], in: store)
    #expect(written.count == 1)
    #expect(written.first?.outcome == .finished)
    #expect(written.first?.requestID == "r1")
    #expect(written.first?.usage == Self.usage)
    #expect(written.first?.costSource == .computed)
    #expect(written.first?.cost == Cost(nanoUSD: 300_000 + 300_000))
    #expect(try await LedgerFixture.entries(store) == written)
  }

  @Test("should close the begun entry as finished for a refusal")
  func refusal() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let events: [ModelEvent] = [.started(requestID: "r1", generationID: "g1"), .finished(usage: Self.usage, reportedCost: nil, stop: .refusal(category: nil))]
    let written = try await Self.finish(call, events, in: store)
    #expect(written.map(\.outcome) == [.finished])
    #expect(try await LedgerFixture.entries(store) == written)
  }

  @Test("should record a provider-reported cost as reported")
  func reportedCost() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let events: [ModelEvent] = [.started(requestID: "r1", generationID: "g1"), .finished(usage: Self.usage, reportedCost: Cost(nanoUSD: 42), stop: .endTurn)]
    let written = try await Self.finish(call, events, catalog: nil, in: store)
    #expect(written.first?.cost == Cost(nanoUSD: 42))
    #expect(written.first?.costSource == .reported)
  }

  @Test("should leave a success pending when there is no catalog")
  func noCatalog() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let written = try await Self.finish(call, [.started(requestID: "r1", generationID: nil), Self.done], catalog: nil, in: store)
    #expect(written.first?.costSource == .pending)
    #expect(written.first?.cost == nil)
  }

  @Test("should turn an abandoned attempt with ids into a pending child entry and close the begun entry with the last attempt")
  func retriedAttempts() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let events: [ModelEvent] = [
      .started(requestID: "r1", generationID: "g1"), Self.retrying(1, request: "r1", generation: "g1"), Self.retrying(2, request: nil, generation: nil),
      .started(requestID: "r3", generationID: nil), .textDelta("ok"), Self.done,
    ]
    let written = try await Self.finish(call, events, in: store)
    #expect(written.count == 2)
    let main = try #require(written.first { $0.id == call.id })
    let child = try #require(written.first { $0.id != call.id })
    #expect(main.outcome == .finished)
    #expect(main.requestID == "r3")
    #expect(main.parent == nil)
    #expect(child.id == Ledger.attemptID(of: call.id, index: 0))
    #expect(child.parent == call.id)
    #expect(child.outcome == .failed)
    #expect(child.generationID == "g1")
    #expect(child.costSource == .pending)
    #expect(child.startedMillis == call.startedMillis)
    #expect(try await LedgerFixture.entries(store).sorted { $0.id.uuidString < $1.id.uuidString } == written.sorted { $0.id.uuidString < $1.id.uuidString })
  }

  @Test("should record the ids of a terminal error after started as a pending failed entry")
  func terminalError() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let written = try await Self.finish(call, [.started(requestID: "r1", generationID: "g1")], error: .server(status: 500), in: store)
    #expect(written.count == 1)
    #expect(written.first?.outcome == .failed)
    #expect(written.first?.requestID == "r1")
    #expect(written.first?.generationID == "g1")
    #expect(written.first?.costSource == .pending)
  }

  @Test("should close the begun entry as failed with zero computed cost when nothing was delivered")
  func errorBeforeAnyEvent() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let written = try await Self.finish(call, [], error: .authentication, in: store)
    #expect(written.count == 1)
    #expect(written.first?.outcome == .failed)
    #expect(written.first?.cost == .zero)
    #expect(written.first?.costSource == .computed)
    #expect(try await LedgerFixture.entries(store) == written)
  }

  @Test("should close a cancelled stream as cancelled and pending")
  func cancellation() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let written = try await Self.finish(call, [.started(requestID: "r1", generationID: "g1"), .textDelta("par")], error: .cancelled, in: store)
    #expect(written.map(\.outcome) == [.cancelled])
    #expect(written.first?.costSource == .pending)
    #expect(try await LedgerFixture.entries(store) == written)
  }

  @Test("should refuse to finish a call that was never begun")
  func finishUnknown() async throws {
    let store = try LedgerFixture.store()
    await #expect(throws: StoreError.self) { _ = try await Self.finish(Self.start(), [.started(requestID: "r", generationID: nil), Self.done], in: store) }
  }

  @Test("should list a call that was begun but never finished as unfinished and count it as pending")
  func crashAfterBegin() async throws {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    let crashed = Self.start(clock)
    clock.advance(by: 60)
    let done = Self.start(clock)
    try await Self.begin(crashed, in: store)
    try await Self.begin(done, in: store)
    _ = try await Self.finish(done, [.started(requestID: "r1", generationID: nil), Self.done], in: store)

    let unfinished = try await store.read { try Ledger.unfinished(in: $0, olderThanMillis: clock.millis) }
    #expect(unfinished.map(\.id) == [crashed.id])
    let none = try await store.read { try Ledger.unfinished(in: $0, olderThanMillis: crashed.startedMillis) }
    #expect(none.isEmpty)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let summary = Spend.summary(of: try await LedgerFixture.entries(store), now: clock.now, calendar: calendar)
    #expect(summary.pendingCalls == 1)
    #expect(summary.today == Cost(nanoUSD: 600_000))
  }

  @Test("should derive a name-based version 8 RFC variant id per call and index")
  func derivesAttemptIDs() {
    let call = UUID()
    let first = Ledger.attemptID(of: call, index: 0)
    #expect(first == Ledger.attemptID(of: call, index: 0))
    #expect(first != Ledger.attemptID(of: call, index: 1))
    #expect(first != Ledger.attemptID(of: UUID(), index: 0))
    #expect(first.uuidString.dropFirst(14).first == "8")
    #expect(["8", "9", "A", "B"].contains(String(first.uuidString.dropFirst(19).prefix(1))))
  }

  private static let retried: [ModelEvent] = [
    .started(requestID: "r1", generationID: "g1"), retrying(1, request: "r1", generation: "g1"), retrying(2, request: "r2", generation: "g2"),
    .started(requestID: "r3", generationID: nil), done,
  ]

  @Test("should give the same entries and leave the store untouched when finished twice")
  func finishIsIdempotent() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let first = try await Self.finish(call, Self.retried, in: store)
    let logged = try await store.pendingChanges(limit: Int.max)
    let second = try await Self.finish(call, Self.retried, in: store)
    #expect(first.count == 3)
    #expect(second == first)
    #expect(try await store.pendingChanges(limit: Int.max) == logged)
    #expect(try await LedgerFixture.entries(store).count == 3)
  }

  @Test("should merge two devices that each finish the same call into the same entries")
  func finishConvergesAcrossDevices() async throws {
    let clock = LedgerTestClock()
    let first = try LedgerFixture.store(clock)
    let second = try LedgerFixture.store(clock)
    let call = Self.start(clock)
    try await Self.begin(call, in: first)
    try await LedgerFixture.exchange(first, second)
    let fromFirst = try await Self.finish(call, Self.retried, in: first)
    clock.advance()
    let fromSecond = try await Self.finish(call, Self.retried, in: second)
    try await LedgerFixture.exchange(first, second)
    let merged = try await LedgerFixture.entries(first)
    #expect(fromFirst == fromSecond)
    #expect(merged.count == 3)
    #expect(try await LedgerFixture.entries(second) == merged)
    #expect(merged.filter { $0.parent == call.id }.count == 2)
  }

  private static let success: [ModelEvent] = [.started(requestID: "r1", generationID: "g1"), .textDelta("hi"), done]

  @Test("should write a finished result over a close as failed made by a sweep")
  func finishAfterSweep() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    try await LedgerFixture.close(call.id, .failed, in: store)
    let written = try await Self.finish(call, Self.success, in: store)
    #expect(written.count == 1)
    #expect(written.first?.outcome == .finished)
    #expect(written.first?.usage == Self.usage)
    #expect(written.first?.cost == Cost(nanoUSD: 600_000))
    #expect(try await LedgerFixture.entries(store) == written)
  }

  @Test("should end finished on both devices whether the sweep's close arrives before or after the finish")
  func finishAndSweepAcrossDevices() async throws {
    for sweepFirst in [true, false] {
      let clock = LedgerTestClock()
      let device = try LedgerFixture.store(clock)
      let sweeper = try LedgerFixture.store(clock)
      let call = Self.start(clock)
      try await Self.begin(call, in: device)
      try await LedgerFixture.exchange(device, sweeper)
      clock.advance()
      if sweepFirst {
        try await LedgerFixture.close(call.id, .failed, in: sweeper)
        try await LedgerFixture.exchange(device, sweeper)
        clock.advance()
        _ = try await Self.finish(call, Self.success, in: device)
      } else {
        _ = try await Self.finish(call, Self.success, in: device)
        clock.advance()
        try await LedgerFixture.close(call.id, .failed, in: sweeper)
      }
      try await LedgerFixture.exchange(device, sweeper)
      let merged = try await LedgerFixture.entries(device)
      #expect(try await LedgerFixture.entries(sweeper) == merged)
      #expect(merged.count == 1)
      #expect(merged.first?.outcome == .finished)
      #expect(merged.first?.usage == Self.usage)
      #expect(merged.first?.cost == Cost(nanoUSD: 600_000))
    }
  }

  @Test("should write once when a failed stream is finished twice")
  func failedFinishIsIdempotent() async throws {
    let store = try LedgerFixture.store()
    let call = Self.start()
    try await Self.begin(call, in: store)
    let events: [ModelEvent] = [Self.retrying(1, request: "r1", generation: "g1"), .started(requestID: "r2", generationID: "g2")]
    let first = try await Self.finish(call, events, error: .server(status: 500), in: store)
    let logged = try await store.pendingChanges(limit: Int.max)
    let second = try await Self.finish(call, events, error: .server(status: 500), in: store)
    #expect(first.count == 2)
    #expect(second == first)
    #expect(try await store.pendingChanges(limit: Int.max) == logged)
  }

  @Test("should keep a provider-reported cost on a failed call")
  func reportedCostOnFailedClose() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry(generationID: "g")
    try await LedgerFixture.open(call, in: store)
    try await LedgerFixture.close(call.id, .failed, cost: Cost(nanoUSD: 12), source: .reported, in: store)
    let entry = try #require(try await LedgerFixture.entries(store).first)
    #expect(entry.cost == Cost(nanoUSD: 12))
    #expect(entry.costSource == .reported)
  }
}
