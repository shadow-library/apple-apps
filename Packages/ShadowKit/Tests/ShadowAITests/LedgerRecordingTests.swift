import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowAI

@Suite("Ledger", .timeLimit(.minutes(1)))
struct LedgerRecordingTests {
  private static let usage = TokenUsage(input: 100, output: 50, cacheRead: 7, cacheWriteShort: 3, cacheWriteLong: 1)

  @Test("should read an opened call back as one started entry")
  func readsOpenedCall() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry(pace: nil, requestID: nil)
    try await LedgerFixture.open(call, in: store)
    #expect(try await LedgerFixture.entries(store) == [call])
  }

  @Test("should read an opened and closed call back as one entry")
  func readsClosedCall() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry(generationID: "gen_1")
    try await LedgerFixture.open(call, in: store)
    try await LedgerFixture.close(call.id, .finished, usage: Self.usage, cost: Cost(nanoUSD: 900), source: .computed, in: store)
    let entries = try await LedgerFixture.entries(store)
    #expect(entries == [LedgerFixture.entry(id: call.id, generationID: "gen_1", outcome: .finished, usage: Self.usage, cost: Cost(nanoUSD: 900), costSource: .computed)])
  }

  @Test("should read a zero computed cost back as zero")
  func readsZeroComputedCost() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry()
    try await LedgerFixture.open(call, in: store)
    try await LedgerFixture.close(call.id, .failed, cost: .zero, source: .computed, in: store)
    let entry = try #require(try await LedgerFixture.entries(store).first)
    #expect(entry.cost == .zero)
    #expect(entry.costSource == .computed)
  }

  @Test("should keep the later outcome in the order when a call is closed twice")
  func keepsLaterOutcome() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry()
    try await LedgerFixture.open(call, in: store)
    try await LedgerFixture.close(call.id, .finished, usage: Self.usage, cost: Cost(nanoUSD: 5), source: .computed, in: store)
    try await LedgerFixture.close(call.id, .failed, in: store)
    let entry = try #require(try await LedgerFixture.entries(store).first)
    #expect(entry.outcome == .finished)
    #expect(entry.usage == Self.usage)
    #expect(entry.cost == Cost(nanoUSD: 5))
    #expect(entry.costSource == .computed)
  }

  @Test("should move a failed outcome forward to cancelled and finished")
  func movesOutcomeForward() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry()
    try await LedgerFixture.open(call, in: store)
    try await LedgerFixture.close(call.id, .failed, in: store)
    #expect(try await LedgerFixture.entries(store).first?.outcome == .failed)
    try await LedgerFixture.close(call.id, .cancelled, in: store)
    #expect(try await LedgerFixture.entries(store).first?.outcome == .cancelled)
    try await LedgerFixture.close(call.id, .started, in: store)
    #expect(try await LedgerFixture.entries(store).first?.outcome == .cancelled)
  }

  @Test("should move a pending cost to reported when reconciled")
  func reconcilesPending() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry(generationID: "gen_1")
    try await LedgerFixture.open(call, in: store)
    try await LedgerFixture.close(call.id, .cancelled, source: .pending, in: store)
    #expect(try await LedgerFixture.entries(store).first?.cost == nil)
    try await LedgerFixture.reconcile(call.id, Cost(nanoUSD: 1_234), in: store)
    let entry = try #require(try await LedgerFixture.entries(store).first)
    #expect(entry.cost == Cost(nanoUSD: 1_234))
    #expect(entry.costSource == .reported)
    #expect(entry.outcome == .cancelled)
  }

  @Test("should not move a reported cost back to pending or computed")
  func reportedCannotGoBack() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry(generationID: "gen_1")
    try await LedgerFixture.open(call, in: store)
    try await LedgerFixture.reconcile(call.id, Cost(nanoUSD: 77), in: store)
    try await LedgerFixture.close(call.id, .failed, source: .pending, in: store)
    try await LedgerFixture.close(call.id, .failed, cost: Cost(nanoUSD: 10), source: .computed, in: store)
    try await LedgerFixture.reconcile(call.id, Cost(nanoUSD: 99), in: store)
    let entry = try #require(try await LedgerFixture.entries(store).first)
    #expect(entry.costSource == .reported)
    #expect(entry.cost == Cost(nanoUSD: 77))
  }

  @Test("should never overwrite an identified request or generation id")
  func identifyNeverOverwrites() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry(requestID: nil)
    try await LedgerFixture.open(call, in: store)
    try await LedgerFixture.identify(call.id, request: nil, generation: nil, in: store)
    try await LedgerFixture.identify(call.id, request: "r1", generation: nil, in: store)
    try await LedgerFixture.identify(call.id, request: "r2", generation: "g2", in: store)
    try await LedgerFixture.identify(call.id, request: "r3", generation: "g3", in: store)
    let entry = try #require(try await LedgerFixture.entries(store).first)
    #expect(entry.requestID == "r1")
    #expect(entry.generationID == "g2")
  }

  @Test("should refuse to identify a call that was never opened")
  func identifyUnknown() async throws {
    let store = try LedgerFixture.store()
    await #expect(throws: StoreError.self) { try await LedgerFixture.identify(UUID(), request: "r", generation: nil, in: store) }
  }

  @Test("should read a parent link back")
  func readsParent() async throws {
    let store = try LedgerFixture.store()
    let parent = UUID()
    let call = LedgerFixture.entry(parent: parent)
    try await LedgerFixture.open(call, in: store)
    #expect(try await LedgerFixture.entries(store).first?.parent == parent)
  }

  @Test("should throw when closing or reconciling a call that was never opened")
  func refusesUnknownCall() async throws {
    let store = try LedgerFixture.store()
    let id = UUID()
    await #expect(throws: StoreError.self) { try await LedgerFixture.close(id, .failed, in: store) }
    await #expect(throws: StoreError.self) { try await LedgerFixture.reconcile(id, .zero, in: store) }
    #expect(try await LedgerFixture.entries(store).isEmpty)
  }

  @Test("should derive a zero cost for a failed call without a generation id and pending with one, whatever cost the close offers")
  func derivesNonFinishedCost() async throws {
    let store = try LedgerFixture.store()
    let plain = LedgerFixture.entry()
    let billable = LedgerFixture.entry(generationID: "gen")
    try await LedgerFixture.open(plain, in: store)
    try await LedgerFixture.open(billable, in: store)
    try await LedgerFixture.close(plain.id, .failed, cost: Cost(nanoUSD: 9), source: .computed, in: store)
    try await LedgerFixture.close(billable.id, .cancelled, cost: Cost(nanoUSD: 9), source: .computed, in: store)
    let entries = try await LedgerFixture.entries(store)
    #expect(entries.first { $0.id == plain.id }?.cost == .zero)
    #expect(entries.first { $0.id == plain.id }?.costSource == .computed)
    #expect(entries.first { $0.id == billable.id }?.cost == nil)
    #expect(entries.first { $0.id == billable.id }?.costSource == .pending)
  }

  @Test("should refuse hosts that are not bare ASCII hosts", arguments: ["host:443", "user@host", "a/b", "a b", "bücher.de", "", ".", "..", "tab\there"])
  func refusesNonBareHosts(_ host: String) async throws {
    let store = try LedgerFixture.store()
    await #expect(throws: StoreError.self) { try await LedgerFixture.open(LedgerFixture.entry(provider: host), in: store) }
  }

  @Test("should normalise the provider host when opening")
  func normalisesProvider() async throws {
    let store = try LedgerFixture.store()
    try await LedgerFixture.open(LedgerFixture.entry(provider: "API.Example.COM.."), in: store)
    #expect(try await LedgerFixture.entries(store).first?.provider == "api.example.com")
  }

  @Test("should refuse an empty provider host")
  func refusesEmptyProvider() async throws {
    let store = try LedgerFixture.store()
    await #expect(throws: StoreError.self) { try await LedgerFixture.open(LedgerFixture.entry(provider: ""), in: store) }
  }

  @Test("should skip malformed entities and return the well-formed ones in start order")
  func skipsMalformed() async throws {
    let store = try LedgerFixture.store()
    let later = LedgerFixture.entry(startedMillis: 2_000)
    let earlier = LedgerFixture.entry(startedMillis: 1_000)
    try await LedgerFixture.open(later, in: store)
    try await LedgerFixture.open(earlier, in: store)

    let good: [String: JSONValue] = ["provider": "h", "model": "m", "task": "writing", "pace": nil, "started": 5, "parent": nil]
    func withCall(_ call: JSONValue, usage: JSONValue? = nil, extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
      var fields: [String: JSONValue] = ["call": call, "outcome": "started"].merging(extra) { $1 }
      if let usage { fields["usage"] = usage }
      return fields
    }
    func badCall(replacing key: String, with value: JSONValue) -> JSONValue {
      var call = good
      call[key] = value
      return .object(call)
    }
    let kind = LedgerSchema.modelCallKind
    let malformed: [(EntityRef, [String: JSONValue])] = [
      (EntityRef(kind: kind, key: EntityKey.natural(scope: "x", kind: kind, components: ["a"])), withCall(.object(good))),
      (EntityRef(kind: kind, key: EntityKey(uuid: UUID())), ["outcome": "started"]),
      (EntityRef(kind: kind, key: EntityKey(uuid: UUID())), withCall("not an object")),
      (EntityRef(kind: kind, key: EntityKey(uuid: UUID())), withCall(badCall(replacing: "task", with: "unknown"))),
      (EntityRef(kind: kind, key: EntityKey(uuid: UUID())), withCall(badCall(replacing: "pace", with: "warp"))),
      (EntityRef(kind: kind, key: EntityKey(uuid: UUID())), withCall(badCall(replacing: "started", with: "soon"))),
      (EntityRef(kind: kind, key: EntityKey(uuid: UUID())), withCall(badCall(replacing: "parent", with: "not-a-uuid"))),
      (EntityRef(kind: kind, key: EntityKey(uuid: UUID())), withCall(.object(good), extra: ["request_id": 3])),
      (EntityRef(kind: kind, key: EntityKey(uuid: UUID())), withCall(.object(good), usage: ["input": "many"])),
      (EntityRef(kind: kind, key: EntityKey(uuid: UUID())), withCall(.object(good), usage: 4)),
    ]
    try await store.write { transaction in
      for (ref, fields) in malformed { _ = try transaction.set(ref, fields) }
    }
    #expect(try await LedgerFixture.entries(store).map(\.id) == [earlier.id, later.id])
  }

  @Test("should accept a stored entity that has no usage or cost fields")
  func readsMinimalEntity() async throws {
    let store = try LedgerFixture.store()
    let id = UUID()
    let call: [String: JSONValue] = ["provider": "h", "model": "m", "task": "chat", "started": 9]
    try await store.write { transaction in
      _ = try transaction.set(EntityRef(kind: LedgerSchema.modelCallKind, key: EntityKey(uuid: id)), ["call": .object(call), "outcome": "finished"])
    }
    let entry = try #require(try await LedgerFixture.entries(store).first)
    #expect(entry.usage == .zero)
    #expect(entry.cost == nil)
    #expect(entry.costSource == .pending)
    #expect(entry.pace == nil)
    #expect(entry.requestID == nil)
  }
}
