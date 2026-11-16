import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowAI

@Suite("LedgerSchema")
struct LedgerSchemaTests {
  private static func schema(_ kind: EntityKind) throws -> EntitySchema {
    try #require(LedgerSchema.entities.first { $0.kind == kind })
  }

  @Test("should declare the model call record with its pinned fields and rules")
  func declaresModelCall() throws {
    let schema = try Self.schema(LedgerSchema.modelCallKind)
    #expect(LedgerSchema.modelCallKind.rawValue == "ai_model_call")
    #expect(schema.syncClass == .general)
    #expect(
      schema.shape
        == .record(fields: [
          "call": .firstWriterWins,
          "request_id": .firstWriterWins,
          "generation_id": .firstWriterWins,
          "outcome": .monotone(order: ["started", "failed", "cancelled", "finished"]),
          "usage": .register,
          "cost_reported": .firstWriterWins,
          "cost_computed": .register,
        ]))
  }

  @Test("should declare the consent record with its pinned fields and rules")
  func declaresConsent() throws {
    let schema = try Self.schema(LedgerSchema.consentKind)
    #expect(LedgerSchema.consentKind.rawValue == "ai_consent")
    #expect(schema.syncClass == .general)
    #expect(schema.shape == .record(fields: ["state": .register, "decided": .register, "summary": .register]))
  }

  @Test("should declare exactly two entity kinds")
  func declaresTwoKinds() {
    #expect(LedgerSchema.entities.map(\.kind.rawValue).sorted() == ["ai_consent", "ai_model_call"])
  }

  @Test("should store the immutable call facts under pinned keys and the ids and costs as separate fields")
  func pinsStoredShape() async throws {
    let store = try LedgerFixture.store()
    let call = LedgerFixture.entry(parent: UUID(), generationID: "gen", outcome: .finished, usage: TokenUsage(input: 1), cost: Cost(nanoUSD: 2), costSource: .computed)
    try await LedgerFixture.open(call, in: store)
    let state = try await store.read { try $0.state(of: EntityRef(kind: LedgerSchema.modelCallKind, key: EntityKey(uuid: call.id))) }
    let record = try #require(state.flatMap { if case .record(let record) = $0 { record } else { nil } })
    #expect(record[field: "call"]?.value.objectValue?.keys.sorted() == ["model", "pace", "parent", "provider", "started", "task"])
    #expect(record[field: "request_id"]?.value == "req_1")
    #expect(record[field: "generation_id"]?.value == "gen")
    #expect(record[field: "cost_computed"]?.value == 2)
    #expect(record[field: "cost_reported"] == nil)
    #expect(record[field: "usage"]?.value.objectValue?.keys.sorted() == ["cache_read", "cache_write_long", "cache_write_short", "input", "output"])
  }

  @Test("should order outcomes and cost sources as the monotone orders")
  func ordersEnums() {
    #expect(LedgerOutcome.order == ["started", "failed", "cancelled", "finished"])
    #expect(LedgerCostSource.pending < .computed)
    #expect(LedgerCostSource.computed < .reported)
  }

  @Test("should build into a registry together with an unrelated app kind")
  func buildsRegistry() throws {
    let store = try LedgerFixture.store()
    #expect(store.registry[LedgerSchema.modelCallKind] != nil)
    #expect(store.registry[LedgerSchema.consentKind] != nil)
    #expect(store.registry[LedgerFixture.noteKind] != nil)
  }
}
