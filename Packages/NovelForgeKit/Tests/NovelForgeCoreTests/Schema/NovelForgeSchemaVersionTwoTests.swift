import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("NovelForgeSchema version 2", .timeLimit(.minutes(1)))
struct NovelForgeSchemaVersionTwoTests {
  private static let novel = SchemaFixture.novel
  private static let proposal = SchemaFixture.proposal

  private static func rules(of kind: NovelForgeKind) throws -> EntityShape {
    try #require(NovelForgeStore.registry[kind.entityKind]).shape
  }

  private static func agreedRecord(_ ref: EntityRef, _ devices: Devices) async throws -> RecordState {
    let record = try await SchemaFixture.record(ref, in: devices.first)
    #expect(record == (try await SchemaFixture.record(ref, in: devices.second)))
    return record
  }

  @Test func shouldDeclareTheChatAndProposalKindsWithTheirMergeRules() throws {
    #expect(
      try Self.rules(of: .chatSession)
        == .record(fields: ["novel": .firstWriterWins, "title": .register, "auto_title": .firstWriterWins, "mode": .register, "status": .register, "removed": .register]))
    #expect(try Self.rules(of: .chatMessage) == .appended)
    #expect(try Self.rules(of: .chatSummary) == .appended)
    #expect(
      try Self.rules(of: .proposal)
        == .record(fields: ["card": .firstWriterWins, "decision": .monotone(order: ["pending", "superseded", "discarded", "applied"]), "applied": .firstWriterWins]))
    #expect(
      try Self.rules(of: .proposalChange)
        == .record(fields: ["natural_key": .firstWriterWins, "status": .register, "undo": .firstWriterWins, "undone_state": .register, "result": .firstWriterWins]))
  }

  @Test func shouldRegisterTheLedgerKindsInTheVaultBesideTheNovelForgeKinds() throws {
    let registry = NovelForgeStore.registry
    for schema in LedgerSchema.entities {
      #expect(registry[schema.kind] == schema)
      #expect(NovelForgeKind(schema.kind) == nil)
    }
  }

  @Test func shouldAcceptALedgerCallAndConsentInTheVault() async throws {
    let store = try SchemaFixture.store()
    let call = EntityRef(kind: LedgerSchema.modelCallKind, key: EntityKey(uuid: UUID()))
    let consent = EntityRef(kind: LedgerSchema.consentKind, key: EntityKey(uuid: UUID()))
    try await SchemaFixture.set(call, ["call": ["provider": "anthropic"]], in: store)
    try await SchemaFixture.set(consent, ["state": "granted"], in: store)
    #expect(try await SchemaFixture.record(call, in: store)[field: "call"]?.value == ["provider": "anthropic"])
    #expect(try await SchemaFixture.record(consent, in: store)[field: "state"]?.value == "granted")
  }

  @Test(arguments: [
    (["superseded", "applied"], "applied"), (["applied", "superseded"], "applied"), (["discarded", "superseded"], "discarded"),
    (["superseded", "discarded"], "discarded"), (["applied", "discarded"], "applied"), (["pending", "superseded"], "superseded"),
  ])
  func shouldSettleConcurrentDecisionsOnTheHigherOne(_ decisions: [String], _ settled: String) async throws {
    let devices = try Devices()
    let ref = NovelForgeKey.proposal(UUID())
    try await SchemaFixture.set(ref, ["card": ["kind": "chat"], "decision": "pending"], in: devices.first)
    try await devices.exchange()
    for (store, decision) in zip(devices.both, decisions) {
      devices.clock.advance()
      try await SchemaFixture.set(ref, ["decision": .string(decision)], in: store)
    }
    try await devices.exchange()
    #expect(try await Self.agreedRecord(ref, devices)[field: "decision"]?.value == .string(settled))
  }

  @Test func shouldNeverLowerADecisionByALaterWrite() async throws {
    let store = try SchemaFixture.store()
    let ref = NovelForgeKey.proposal(UUID())
    try await SchemaFixture.set(ref, ["card": ["kind": "chat"], "decision": "applied"], in: store)
    try await SchemaFixture.set(ref, ["decision": "pending"], in: store)
    #expect(try await SchemaFixture.record(ref, in: store)[field: "decision"]?.value == "applied")
  }

  @Test(arguments: ["conflicted", "reverted", "Applied"])
  func shouldRefuseADecisionOutsideTheOrder(_ decision: String) async throws {
    let store = try SchemaFixture.store()
    await #expect(throws: StoreError.self) { try await SchemaFixture.set(NovelForgeKey.proposal(UUID()), ["decision": .string(decision)], in: store) }
  }

  @Test func shouldKeepTheFirstCardAppliedObjectUndoAndResultWritten() async throws {
    let devices = try Devices()
    let proposal = NovelForgeKey.proposal(Self.proposal)
    let change = try NovelForgeKey.proposalChangeKey(novel: Self.novel, proposal: Self.proposal, index: 0)
    for (store, device) in zip(devices.both, ["first", "second"]) {
      try await SchemaFixture.set(proposal, ["card": ["run": .string(device)], "applied": ["automatic": .string(device)], "decision": "applied"], in: store)
      try await SchemaFixture.set(
        change.ref, ["natural_key": change.stored, "status": "applied", "undo": ["inverse": .string(device)], "result": ["note": .string(device)]], in: store)
      devices.clock.advance()
    }
    try await devices.exchange()
    let card = try await Self.agreedRecord(proposal, devices)
    #expect(card[field: "card"]?.value == ["run": "first"])
    #expect(card[field: "applied"]?.value == ["automatic": "first"])
    let undone = try await Self.agreedRecord(change.ref, devices)
    #expect(undone[field: "undo"]?.value == ["inverse": "first"])
    #expect(undone[field: "result"]?.value == ["note": "first"])
    for store in devices.both { #expect(try await SchemaFixture.count(.proposalChange, in: store) == 1) }
  }

  @Test func shouldRecordTheUnionOfTwoConcurrentAppliesOfDifferentSelections() async throws {
    let devices = try Devices()
    let proposal = NovelForgeKey.proposal(Self.proposal)
    try await SchemaFixture.set(proposal, ["card": ["novel": .string(Self.novel.uuidString.lowercased())], "decision": "pending"], in: devices.first)
    try await devices.exchange()
    for (store, (device, selected)) in zip(devices.both, [("first", [0, 1]), ("second", [1, 2])]) {
      devices.clock.advance()
      _ = try await store.write { transaction in
        _ = try transaction.set(proposal, ["decision": "applied", "applied": ["automatic": .string(device)]])
        for index in selected {
          let change = try NovelForgeKey.proposalChangeKey(novel: Self.novel, proposal: Self.proposal, index: index)
          let undo: JSONValue = ["inverse": .string(device), "prior_state": [:], "post_state": [:]]
          _ = try transaction.set(change.ref, ["natural_key": change.stored, "status": "applied", "undo": undo])
        }
      }
    }
    try await devices.exchange()
    let settled = try await Self.agreedRecord(proposal, devices)
    #expect(settled[field: "decision"]?.value == "applied")
    #expect(settled[field: "applied"]?.value == ["automatic": "first"])
    for store in devices.both {
      let recorded = try await store.read { transaction in try transaction.states(ofKind: NovelForgeKind.proposalChange.entityKind).map(\.ref) }
      let expected = try [0, 1, 2].map { index throws(NovelForgeKeyError) in try NovelForgeKey.proposalChange(novel: Self.novel, proposal: Self.proposal, index: index) }
      #expect(Set(recorded) == Set(expected))
    }
    let shared = try NovelForgeKey.proposalChange(novel: Self.novel, proposal: Self.proposal, index: 1)
    #expect(try await Self.agreedRecord(shared, devices)[field: "undo"]?.value == ["inverse": "first", "prior_state": [:], "post_state": [:]])
  }

  @Test func shouldNeverMoveAChatToAnotherNovel() async throws {
    let devices = try Devices()
    let session = NovelForgeKey.chatSession(UUID())
    for (store, novel) in zip(devices.both, [SchemaFixture.novel, SchemaFixture.otherNovel]) {
      try await SchemaFixture.set(session, ["novel": .string(novel.uuidString.lowercased())], in: store)
      devices.clock.advance()
    }
    try await SchemaFixture.set(session, ["novel": .string(SchemaFixture.otherNovel.uuidString.lowercased())], in: devices.first)
    try await devices.exchange()
    #expect(try await Self.agreedRecord(session, devices)[field: "novel"]?.value == .string(SchemaFixture.novel.uuidString.lowercased()))
  }

  @Test func shouldLetTheLaterUndoOrRedoOfAChangeStand() async throws {
    let devices = try Devices()
    let change = try NovelForgeKey.proposalChangeKey(novel: Self.novel, proposal: Self.proposal, index: 2)
    try await SchemaFixture.set(change.ref, ["natural_key": change.stored, "status": "applied"], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    try await SchemaFixture.set(change.ref, ["status": "reverted", "undone_state": ["n:a": "gone"]], in: devices.first)
    devices.clock.advance()
    try await SchemaFixture.set(change.ref, ["status": "applied"], in: devices.second)
    try await devices.exchange()
    let record = try await Self.agreedRecord(change.ref, devices)
    #expect(record[field: "status"]?.value == "applied")
    #expect(record[field: "undone_state"]?.value == ["n:a": "gone"])
  }

  @Test(arguments: [true, false])
  func shouldKeepADeletedChatDeletedWhenAnArchiveArrives(_ archiveLater: Bool) async throws {
    let devices = try Devices()
    let session = NovelForgeKey.chatSession(UUID())
    try await SchemaFixture.set(session, ["title": .null, "mode": "auto", "status": "active", "removed": false], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    if !archiveLater { try await SchemaFixture.set(session, ["status": "archived"], in: devices.second) }
    devices.clock.advance()
    try await SchemaFixture.set(session, ["removed": true], in: devices.first)
    devices.clock.advance()
    if archiveLater { try await SchemaFixture.set(session, ["status": "archived"], in: devices.second) }
    try await devices.exchange()
    let record = try await Self.agreedRecord(session, devices)
    #expect(record[field: "removed"]?.value == true)
    #expect(record[field: "status"]?.value == "archived")
  }

  @Test func shouldNeverLetAGeneratedTitleReplaceTheAuthorsTitle() async throws {
    let devices = try Devices()
    let session = NovelForgeKey.chatSession(UUID())
    try await SchemaFixture.set(session, ["title": .null, "mode": "auto", "status": "active", "removed": false], in: devices.first)
    try await devices.exchange()
    devices.clock.advance()
    try await SchemaFixture.set(session, ["title": "Aria's arc"], in: devices.first)
    try await SchemaFixture.set(session, ["auto_title": "Opening chapter"], in: devices.first)
    devices.clock.advance()
    try await SchemaFixture.set(session, ["auto_title": "Chapter one"], in: devices.second)
    try await devices.exchange()
    let record = try await Self.agreedRecord(session, devices)
    #expect(record[field: "title"]?.value == "Aria's arc")
    #expect(record[field: "auto_title"]?.value == "Opening chapter")
  }

  @Test func shouldKeepAnAutoTitleWrittenAsNullAtCreateForEver() async throws {
    let store = try SchemaFixture.store()
    let session = NovelForgeKey.chatSession(UUID())
    try await SchemaFixture.set(session, ["auto_title": .null], in: store)
    try await SchemaFixture.set(session, ["auto_title": "Opening chapter"], in: store)
    #expect(try await SchemaFixture.record(session, in: store)[field: "auto_title"]?.value == .null)
  }

  @Test func shouldAppendMessagesAndSummariesWithoutLaterFields() async throws {
    let store = try SchemaFixture.store()
    for ref in [NovelForgeKey.chatMessage(UUID()), NovelForgeKey.chatSummary(UUID())] {
      _ = try await store.write { transaction in try transaction.append(ref, item: ["novel": .string(Self.novel.uuidString.lowercased())]) }
      await #expect(throws: StoreError.self) { try await SchemaFixture.set(ref, ["held": "warnings"], in: store) }
    }
  }
}
