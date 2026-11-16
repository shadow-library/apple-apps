import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("Ledger merge", .timeLimit(.minutes(1)))
struct LedgerMergeTests {
  private static let usage = TokenUsage(input: 40, output: 10)

  private struct Devices {
    let clock = LedgerTestClock()
    let first: VaultStore
    let second: VaultStore

    init() throws {
      first = try LedgerFixture.store(clock)
      second = try LedgerFixture.store(clock)
    }

    func exchange() async throws {
      try await LedgerFixture.exchange(first, second)
    }

    func agreedEntries() async throws -> [ModelCallEntry] {
      let mine = try await LedgerFixture.entries(first)
      #expect(mine == (try await LedgerFixture.entries(second)))
      return mine
    }
  }

  @Test("should merge the same call opened on both devices into one entry")
  func mergesSameCall() async throws {
    let devices = try Devices()
    let id = UUID()
    try await LedgerFixture.open(LedgerFixture.entry(id: id, model: "first-model"), in: devices.first)
    devices.clock.advance()
    try await LedgerFixture.open(LedgerFixture.entry(id: id, model: "second-model"), in: devices.second)
    try await devices.exchange()
    let entries = try await devices.agreedEntries()
    #expect(entries.count == 1)
    #expect(entries.first?.model == "first-model")
  }

  @Test("should end finished on both devices when one closes failed and the other finished")
  func finishedBeatsFailed() async throws {
    let devices = try Devices()
    let call = LedgerFixture.entry()
    try await LedgerFixture.open(call, in: devices.first)
    try await devices.exchange()
    try await LedgerFixture.close(call.id, .finished, usage: Self.usage, cost: Cost(nanoUSD: 300), source: .computed, in: devices.first)
    devices.clock.advance()
    try await LedgerFixture.close(call.id, .failed, in: devices.second)
    try await devices.exchange()
    let entry = try #require(try await devices.agreedEntries().first)
    #expect(entry.outcome == .finished)
    #expect(entry.usage == Self.usage)
    #expect(entry.cost == Cost(nanoUSD: 300))
  }

  @Test("should end finished when the failing device closes first")
  func finishedBeatsEarlierFailed() async throws {
    let devices = try Devices()
    let call = LedgerFixture.entry()
    try await LedgerFixture.open(call, in: devices.first)
    try await devices.exchange()
    try await LedgerFixture.close(call.id, .failed, in: devices.second)
    devices.clock.advance()
    try await LedgerFixture.close(call.id, .finished, usage: Self.usage, cost: Cost(nanoUSD: 300), source: .computed, in: devices.first)
    try await devices.exchange()
    #expect(try await devices.agreedEntries().first?.outcome == .finished)
  }

  @Test("should let a reported cost win in every order")
  func reportedWinsInEveryOrder() async throws {
    for reportedFirst in [true, false] {
      let devices = try Devices()
      let call = LedgerFixture.entry(generationID: "gen_1")
      try await LedgerFixture.open(call, in: devices.first)
      try await devices.exchange()
      if reportedFirst { try await LedgerFixture.reconcile(call.id, Cost(nanoUSD: 450), in: devices.second) }
      devices.clock.advance()
      try await LedgerFixture.close(call.id, .finished, usage: Self.usage, cost: Cost(nanoUSD: 300), source: .computed, in: devices.first)
      devices.clock.advance()
      if !reportedFirst { try await LedgerFixture.reconcile(call.id, Cost(nanoUSD: 450), in: devices.second) }
      try await devices.exchange()
      let entry = try #require(try await devices.agreedEntries().first)
      #expect(entry.costSource == .reported)
      #expect(entry.cost == Cost(nanoUSD: 450))
      #expect(entry.outcome == .finished)
    }
  }

  @Test("should never replace a reported cost")
  func reportedIsNeverReplaced() async throws {
    let devices = try Devices()
    let call = LedgerFixture.entry(generationID: "gen_1")
    try await LedgerFixture.open(call, in: devices.first)
    try await devices.exchange()
    try await LedgerFixture.reconcile(call.id, Cost(nanoUSD: 10), in: devices.first)
    devices.clock.advance()
    try await LedgerFixture.reconcile(call.id, Cost(nanoUSD: 20), in: devices.second)
    try await devices.exchange()
    #expect(try await devices.agreedEntries().first?.cost == Cost(nanoUSD: 10))
  }

  @Test("should converge two different computed costs to the later one")
  func computedConvergesToLater() async throws {
    let devices = try Devices()
    let call = LedgerFixture.entry()
    try await LedgerFixture.open(call, in: devices.first)
    try await devices.exchange()
    try await LedgerFixture.close(call.id, .finished, usage: Self.usage, cost: Cost(nanoUSD: 300), source: .computed, in: devices.first)
    devices.clock.advance()
    try await LedgerFixture.close(call.id, .finished, usage: Self.usage, cost: Cost(nanoUSD: 310), source: .computed, in: devices.second)
    try await devices.exchange()
    let entry = try #require(try await devices.agreedEntries().first)
    #expect(entry.cost == Cost(nanoUSD: 310))
    #expect(entry.costSource == .computed)
  }

  @Test("should let a computed cost beat a pending one on both devices")
  func computedBeatsPending() async throws {
    let devices = try Devices()
    let call = LedgerFixture.entry()
    try await LedgerFixture.open(call, in: devices.first)
    try await devices.exchange()
    try await LedgerFixture.close(call.id, .finished, usage: Self.usage, cost: Cost(nanoUSD: 300), source: .computed, in: devices.first)
    devices.clock.advance()
    try await LedgerFixture.close(call.id, .failed, source: .pending, in: devices.second)
    try await devices.exchange()
    let entry = try #require(try await devices.agreedEntries().first)
    #expect(entry.costSource == .computed)
    #expect(entry.cost == Cost(nanoUSD: 300))
    #expect(entry.usage == Self.usage)
  }

  @Test("should keep the first identified request and generation ids on both devices")
  func idsFirstWriterWins() async throws {
    let devices = try Devices()
    let call = LedgerFixture.entry(requestID: nil)
    try await LedgerFixture.open(call, in: devices.first)
    try await devices.exchange()
    try await LedgerFixture.identify(call.id, request: "first", generation: nil, in: devices.first)
    devices.clock.advance()
    try await LedgerFixture.identify(call.id, request: "second", generation: "gen", in: devices.second)
    try await devices.exchange()
    let entry = try #require(try await devices.agreedEntries().first)
    #expect(entry.requestID == "first")
    #expect(entry.generationID == "gen")
  }

  @Test("should end finished with the real cost when a failed close meets a finished one in either clock order")
  func failedCloseCannotEraseCost() async throws {
    for failedLater in [true, false] {
      let devices = try Devices()
      let call = LedgerFixture.entry()
      try await LedgerFixture.open(call, in: devices.first)
      try await devices.exchange()
      if !failedLater { try await LedgerFixture.close(call.id, .failed, cost: .zero, source: .computed, in: devices.second) }
      devices.clock.advance()
      try await LedgerFixture.close(call.id, .finished, usage: Self.usage, cost: Cost(nanoUSD: 300), source: .computed, in: devices.first)
      devices.clock.advance()
      if failedLater { try await LedgerFixture.close(call.id, .failed, cost: .zero, source: .computed, in: devices.second) }
      try await devices.exchange()
      let entry = try #require(try await devices.agreedEntries().first)
      #expect(entry.outcome == .finished)
      #expect(entry.cost == Cost(nanoUSD: 300))
      #expect(entry.costSource == .computed)
      #expect(entry.usage == Self.usage)
    }
  }

  @Test("should keep two different calls as two entries on both devices")
  func keepsDifferentCalls() async throws {
    let devices = try Devices()
    let one = LedgerFixture.entry(startedMillis: 1_000)
    let two = LedgerFixture.entry(startedMillis: 2_000)
    try await LedgerFixture.open(one, in: devices.first)
    try await LedgerFixture.open(two, in: devices.second)
    try await devices.exchange()
    #expect(try await devices.agreedEntries().map(\.id) == [one.id, two.id])
  }

  @Test("should converge on equal entries for random interleavings of opens, closes and reconciles")
  func convergesRandomly() async throws {
    try await forAll(iterations: 40) { generator in
      let devices = try Devices()
      let ids = (0..<3).map { _ in UUID() }
      var opened: Set<UUID> = []
      var knownTo: [Set<UUID>] = [[], []]
      for _ in 0..<generator.int(in: 4...14) {
        let side = generator.int(in: 0...1)
        let store = side == 0 ? devices.first : devices.second
        let id = generator.pick(from: ids)
        devices.clock.advance()
        switch generator.int(in: 0...3) {
        case 0:
          try await LedgerFixture.open(LedgerFixture.entry(id: id, generationID: "g"), in: store)
          opened.insert(id)
          knownTo[side].insert(id)
        case 1 where knownTo[side].contains(id):
          let outcome = generator.pick(from: [LedgerOutcome.failed, .cancelled, .finished])
          try await LedgerFixture.close(id, outcome, usage: Self.usage, cost: Cost(nanoUSD: Int64(generator.int(in: 0...9))), source: .computed, in: store)
        case 2 where knownTo[side].contains(id):
          try await LedgerFixture.reconcile(id, Cost(nanoUSD: Int64(generator.int(in: 0...9))), in: store)
        default:
          continue
        }
      }
      try await devices.exchange()
      let entries = try await devices.agreedEntries()
      #expect(Set(entries.map(\.id)) == opened)
      #expect(entries.count == opened.count)
    }
  }
}
