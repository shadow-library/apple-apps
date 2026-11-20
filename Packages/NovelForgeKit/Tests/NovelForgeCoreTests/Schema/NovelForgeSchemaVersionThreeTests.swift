import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowSync
import ShadowText
import Testing

@testable import NovelForgeCore

@Suite("NovelForgeSchema version 3", TestTimeLimit.standard)
struct NovelForgeSchemaVersionThreeTests {
  private static let novel = SchemaFixture.novel
  private static let novelID = JSONValue.string(SchemaFixture.novel.uuidString.lowercased())

  private static func rules(of kind: NovelForgeKind) throws -> EntityShape {
    try #require(NovelForgeStore.registry[kind.entityKind]).shape
  }

  private static func agreedRecord(_ ref: EntityRef, _ devices: Devices) async throws -> RecordState {
    let record = try await SchemaFixture.record(ref, in: devices.first)
    #expect(record == (try await SchemaFixture.record(ref, in: devices.second)))
    return record
  }

  @Test func shouldDeclareTheChapterReviewAndFinalizeKindsWithTheirMergeRules() throws {
    #expect(try Self.rules(of: .chapterReview) == .appended)
    #expect(try Self.rules(of: .reviewRemedy) == .record(fields: ["natural_key": .firstWriterWins, "remedy": .register]))
    #expect(try Self.rules(of: .finalizeReview) == .appended)
    #expect(try Self.rules(of: .finalizeDecision) == .record(fields: ["natural_key": .firstWriterWins, "decision": .register]))
    #expect(try Self.rules(of: .refreshReport) == .appended)
  }

  @Test func shouldDeclareTheEntityAgeAndTheNovelAutoKeepAsTypedRegisters() throws {
    let entity = try Self.rules(of: .entity)
    let novel = try Self.rules(of: .novel)
    guard case .record(let entityFields) = entity, case .record(let novelFields) = novel else { throw SchemaFixtureError(description: "entity and novel are records") }
    #expect(entityFields["age"] == .register)
    #expect(novelFields["auto_keep"] == .register)
    #expect(EntityField.age.rawValue == "age")
    #expect(NovelField.autoKeep.rawValue == "auto_keep")
    #expect(Set(entityFields.keys) == Set(EntityField.allCases.map(\.rawValue) + ["natural_key", "removed"]))
    #expect(Set(novelFields.keys) == Set(NovelField.allCases.map(\.rawValue)))
  }

  @Test func shouldRegisterTheLedgerAndJobKindsInTheVaultBesideTheNovelForgeKinds() throws {
    let registry = NovelForgeStore.registry
    #expect(registry.version == NovelForgeSchema.version)
    let described = try JSONDecoder().decode(JSONValue.self, from: registry.canonicalDescription())
    let kinds = try #require(described["kinds"]?.arrayValue).compactMap { $0["kind"]?.stringValue }
    #expect(
      Set(kinds) == Set(NovelForgeKind.allCases.map(\.rawValue) + ["ai_model_call", "ai_consent", "jobs_job", "jobs_attempt"] + SyncKernelSchema.entities.map(\.kind.rawValue)))
    #expect(kinds.count == NovelForgeKind.allCases.count + 4 + SyncKernelSchema.entities.count)
    for schema in JobSchema.entities {
      #expect(registry[schema.kind] == schema)
      #expect(NovelForgeKind(schema.kind) == nil)
    }
  }

  @Test func shouldAcceptAJobAndAnAttemptInTheVault() async throws {
    let store = try SchemaFixture.store()
    let job = try JobKey(scope: SchemaFixture.novel.uuidString.lowercased(), kind: "generate", target: "chapter:3", fingerprint: "f0", run: 1)
    let attempt = try AttemptID(UUID.v7()).ref
    try await SchemaFixture.set(job.ref, ["request": .object(job.requestMembers), "cancel": "none"], in: store)
    try await SchemaFixture.set(attempt, ["start": ["job": .string(job.ref.key.rawValue)], "outcome": "running", "calls": []], in: store)
    #expect(try await SchemaFixture.record(job.ref, in: store)[field: "cancel"]?.value == "none")
    #expect(try await SchemaFixture.record(attempt, in: store)[field: "outcome"]?.value == "running")
  }

  @Test func shouldLetTheLaterRemedyAndDecisionStand() async throws {
    let devices = try Devices()
    let remedy = NovelForgeKey.reviewRemedyKey(novel: Self.novel, review: SchemaFixture.review, finding: "f1")
    let decision = try NovelForgeKey.finalizeDecisionKey(novel: Self.novel, chapter: 2, draftRevision: SchemaFixture.draftRevision, item: "entity:aria")
    for (store, answer) in zip(devices.both, ["kept", "skipped"]) {
      try await SchemaFixture.set(remedy.ref, ["natural_key": remedy.stored, "remedy": ["action": .string(answer)]], in: store)
      try await SchemaFixture.set(decision.ref, ["natural_key": decision.stored, "decision": ["decision": .string(answer)]], in: store)
      devices.clock.advance()
    }
    try await devices.exchange()
    #expect(try await Self.agreedRecord(remedy.ref, devices)[field: "remedy"]?.value == ["action": "skipped"])
    #expect(try await Self.agreedRecord(decision.ref, devices)[field: "decision"]?.value == ["decision": "skipped"])
    for store in devices.both {
      #expect(try await SchemaFixture.count(.reviewRemedy, in: store) == 1)
      #expect(try await SchemaFixture.count(.finalizeDecision, in: store) == 1)
    }
  }

  @Test func shouldAppendReviewsAndReportsWithoutLaterFields() async throws {
    let store = try SchemaFixture.store()
    for ref in [NovelForgeKey.chapterReview(UUID()), NovelForgeKey.finalizeReview(UUID()), NovelForgeKey.refreshReport(UUID())] {
      _ = try await store.write { transaction in try transaction.append(ref, item: ["novel": Self.novelID, "items": []]) }
      await #expect(throws: StoreError.self) { try await SchemaFixture.set(ref, ["disposition": "clear"], in: store) }
    }
  }
}
