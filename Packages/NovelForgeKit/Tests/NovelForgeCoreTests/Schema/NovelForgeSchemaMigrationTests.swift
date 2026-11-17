import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("NovelForgeSchema migration", .timeLimit(.minutes(1)))
struct NovelForgeSchemaMigrationTests {
  private static let novel = SchemaFixture.novel
  private static let novelID = JSONValue.string(SchemaFixture.novel.uuidString.lowercased())

  private static func versionOne() throws -> SchemaRegistry {
    try SchemaRegistry(canonicalDescription: try ReferenceFixture.data("schema/registry-v1.json"))
  }

  private static func openAtVersionOne(_ url: URL) throws -> VaultStore {
    let registry = try versionOne()
    let reconciler = try NovelForgeReconciler(registry: registry)
    return try VaultStore.open(.file(url), registry: registry, migrations: reconciler.migrations, reconciler: reconciler)
  }

  private static func temporaryVault() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "NovelForgeSchemaMigrationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "vault.sqlite")
  }

  @Test func shouldOpenAVaultWrittenAtVersionOneAtVersionTwoAndAdoptWhatItHeldForeign() async throws {
    let url = try Self.temporaryVault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let newer = try NovelForgeStore.openInMemory()
    let session = NovelForgeKey.chatSession(UUID())
    let message = NovelForgeKey.chatMessage(UUID())
    let call = EntityRef(kind: LedgerSchema.modelCallKind, key: EntityKey(uuid: UUID()))
    _ = try await newer.write { transaction in
      _ = try transaction.set(session, ["novel": Self.novelID, "title": "Openings", "mode": "auto", "status": "active", "removed": false])
      _ = try transaction.append(message, item: ["novel": Self.novelID, "session": .string(session.key.rawValue), "role": "user", "content": "Hello"])
      _ = try transaction.set(call, ["call": ["provider": "anthropic"]])
    }
    let sent = try await newer.pendingChanges(limit: Int.max).map(\.line)
    do {
      let old = try Self.openAtVersionOne(url)
      _ = try await old.write { transaction in try NovelRecord(id: Self.novel, name: "Ember").create(in: &transaction) }
      _ = try await old.applyRemote(sent)
      for ref in [session, message, call] { #expect(try await SchemaFixture.state(ref, in: old) == nil) }
    }

    let upgraded = try NovelForgeStore.open(at: url)
    #expect(try await upgraded.load(LibraryList.self).novels.map(\.novel.name) == ["Ember"])
    #expect(try await SchemaFixture.record(session, in: upgraded)[field: "title"]?.value == "Openings")
    guard case .appended(let appended)? = try await SchemaFixture.state(message, in: upgraded) else { throw SchemaFixtureError(description: "the message was not adopted") }
    #expect(appended.item["content"] == "Hello")
    #expect(try await SchemaFixture.record(call, in: upgraded)[field: "call"]?.value == ["provider": "anthropic"])
    let proposal = NovelForgeKey.proposal(UUID())
    try await SchemaFixture.set(proposal, ["card": ["novel": Self.novelID], "decision": "pending"], in: upgraded)
    #expect(try await SchemaFixture.record(proposal, in: upgraded)[field: "decision"]?.value == "pending")
  }

  @Test func shouldRefuseToReopenAVersionTwoVaultWithTheVersionOneSchema() throws {
    let url = try Self.temporaryVault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = try NovelForgeStore.open(at: url)
    #expect(throws: StoreError.self) { try Self.openAtVersionOne(url) }
  }

  @Test func shouldKeepADecisionALaterVersionAddsOutOfTheRecordUntilTheUpgrade() async throws {
    let extended = NovelForgeSchema.entities.map { schema in
      guard schema.kind == NovelForgeKind.proposal.entityKind, case .record(var fields) = schema.shape else { return schema }
      fields["decision"] = .monotone(order: ["pending", "conflicted", "superseded", "discarded", "applied"])
      return EntitySchema(kind: schema.kind, shape: .record(fields: fields), syncClass: schema.syncClass)
    }
    let later = SchemaRegistry(version: NovelForgeSchema.version + 1, entities: extended + LedgerSchema.entities)
    #expect(later.incompatibilities(with: NovelForgeSchema.registry) == [])
    let newer = try VaultStore.open(.inMemory, registry: later)
    let proposal = NovelForgeKey.proposal(UUID())
    _ = try await newer.write { transaction in try transaction.set(proposal, ["card": ["novel": Self.novelID], "decision": "conflicted"]) }
    let store = try SchemaFixture.store()
    _ = try await store.applyRemote(try await newer.pendingChanges(limit: Int.max).map(\.line))
    let record = try await SchemaFixture.record(proposal, in: store)
    #expect(record[field: "card"]?.value == ["novel": Self.novelID])
    #expect(record[field: "decision"] == nil)
  }
}
