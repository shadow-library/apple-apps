import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowSync
import Testing

@testable import NovelForgeCore

@Suite("NovelForgeSchema migration", TestTimeLimit.standard)
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

  private static func openAtVersionTwo(_ url: URL) throws -> VaultStore {
    let registry = try SchemaRegistry(canonicalDescription: try ReferenceFixture.data("schema/registry-v2.json"))
    let reconciler = try NovelForgeReconciler(registry: registry)
    return try VaultStore.open(.file(url), registry: registry, migrations: reconciler.migrations, reconciler: reconciler)
  }

  private static func openAtVersionThree(_ url: URL) throws -> VaultStore {
    let registry = try SchemaRegistry(canonicalDescription: try ReferenceFixture.data("schema/registry-v3.json"))
    let reconciler = try NovelForgeReconciler(registry: registry)
    return try VaultStore.open(.file(url), registry: registry, migrations: reconciler.migrations, reconciler: reconciler)
  }

  private static func openAtVersionFour(_ url: URL) throws -> VaultStore {
    let registry = try SchemaRegistry(canonicalDescription: try ReferenceFixture.data("schema/registry-v4.json"))
    let reconciler = try NovelForgeReconciler(registry: registry)
    return try VaultStore.open(.file(url), registry: registry, migrations: reconciler.migrations, reconciler: reconciler)
  }

  private static func review(of chapter: Int, in store: VaultStore) async throws -> DraftReviewState? {
    try await store.read { transaction in try ChapterLifecycleEntry.read(novel: novel, chapter: chapter, in: transaction.database)?.review }
  }

  private static func createNovelAsAnEarlierVersion(in transaction: inout WriteTransaction) throws -> ChangeRecord {
    let record = NovelRecord(id: novel, name: "Ember")
    return try transaction.set(record.ref, record.storedMembers.filter { $0.key != NovelField.autoKeep.rawValue })
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
      _ = try await old.write { transaction in try Self.createNovelAsAnEarlierVersion(in: &transaction) }
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

  @Test func shouldOpenAVaultWrittenAtVersionTwoAtVersionThreeWithItsDataIntactAndAdoptWhatItHeldForeign() async throws {
    let url = try Self.temporaryVault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let session = NovelForgeKey.chatSession(UUID())
    let proposal = NovelForgeKey.proposal(UUID())
    let entity = NovelForgeKey.entityKey(novel: Self.novel, entity: "aria")
    let job = try JobKey(scope: SchemaFixture.novel.uuidString.lowercased(), kind: "generate", target: "chapter:1", fingerprint: "f0", run: 1)
    let attempt = try AttemptID(UUID.v7()).ref
    let review = NovelForgeKey.chapterReview(UUID())
    let decision = try NovelForgeKey.finalizeDecisionKey(novel: Self.novel, chapter: 1, draftRevision: SchemaFixture.draftRevision, item: "entity:aria")
    let newer = try NovelForgeStore.openInMemory()
    _ = try await newer.write { transaction in
      _ = try transaction.set(entity.ref, ["natural_key": entity.stored, "name": "Aria", "age": 16, "removed": false])
      _ = try transaction.set(NovelForgeKey.novel(Self.novel), ["auto_keep": ["summary"]])
      _ = try transaction.set(job.ref, ["request": .object(job.requestMembers), "cancel": "none"])
      _ = try transaction.set(attempt, ["start": ["job": .string(job.ref.key.rawValue)], "outcome": "running"])
      _ = try transaction.append(review, item: ["novel": Self.novelID, "chapter": 1, "kind": "judge"])
      _ = try transaction.set(decision.ref, ["natural_key": decision.stored, "decision": ["decision": "kept"]])
    }
    let sent = try await newer.pendingChanges(limit: Int.max).map(\.line)
    do {
      let old = try Self.openAtVersionTwo(url)
      _ = try await old.write { transaction in
        _ = try Self.createNovelAsAnEarlierVersion(in: &transaction)
        _ = try transaction.set(session, ["novel": Self.novelID, "title": "Openings", "mode": "auto", "status": "active", "removed": false])
        _ = try transaction.set(proposal, ["card": ["novel": Self.novelID], "decision": "applied"])
      }
      _ = try await old.applyRemote(sent)
      for ref in [job.ref, attempt, review, decision.ref] { #expect(try await SchemaFixture.state(ref, in: old) == nil) }
      let held = try await SchemaFixture.record(entity.ref, in: old)
      #expect(held[field: "name"]?.value == "Aria")
      #expect(held[field: "age"] == nil)
      #expect(try await SchemaFixture.record(NovelForgeKey.novel(Self.novel), in: old)[field: "auto_keep"] == nil)
      await #expect(throws: StoreError.self) { try await SchemaFixture.set(job.ref, ["cancel": "requested"], in: old) }
      await #expect(throws: StoreError.self) { try await SchemaFixture.set(entity.ref, ["age": 17], in: old) }
    }

    let upgraded = try NovelForgeStore.open(at: url)
    #expect(try await upgraded.load(LibraryList.self).novels.map(\.novel.name) == ["Ember"])
    #expect(try await SchemaFixture.record(session, in: upgraded)[field: "title"]?.value == "Openings")
    #expect(try await SchemaFixture.record(proposal, in: upgraded)[field: "decision"]?.value == "applied")
    #expect(try await SchemaFixture.record(NovelForgeKey.novel(Self.novel), in: upgraded)[field: "auto_keep"]?.value == ["summary"])
    let adopted = try await SchemaFixture.record(entity.ref, in: upgraded)
    #expect(adopted[field: "name"]?.value == "Aria")
    #expect(adopted[field: "age"]?.value == 16)
    #expect(try await SchemaFixture.record(job.ref, in: upgraded)[field: "request"]?.value == .object(job.requestMembers))
    #expect(try await SchemaFixture.record(attempt, in: upgraded)[field: "outcome"]?.value == "running")
    #expect(try await SchemaFixture.record(decision.ref, in: upgraded)[field: "decision"]?.value == ["decision": "kept"])
    guard case .appended(let appended)? = try await SchemaFixture.state(review, in: upgraded) else { throw SchemaFixtureError(description: "the review was not adopted") }
    #expect(appended.item["kind"] == "judge")
  }

  @Test func shouldRefuseToReopenAVersionThreeVaultWithTheVersionTwoSchema() throws {
    let url = try Self.temporaryVault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = try NovelForgeStore.open(at: url)
    #expect(throws: StoreError.self) { try Self.openAtVersionTwo(url) }
  }

  @Test func shouldOpenAVaultWrittenAtVersionThreeAtVersionFourAndHoldTheRewriteALaterDeviceHeld() async throws {
    let url = try Self.temporaryVault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let rewritten = try DraftRecord.ref(novel: Self.novel, chapter: 2)
    let newer = try NovelForgeStore.openInMemory()
    _ = try await newer.write { transaction in
      _ = try DraftRecord(novel: Self.novel, chapter: 2, content: DraftContent(body: "The ledger.", source: .known(.handEdited))).create(in: &transaction)
      guard case .revisioned(let state)? = try transaction.state(of: rewritten) else { throw SchemaFixtureError(description: "the draft has no head") }
      var content = DraftContent(body: "The ledger is forged.", source: .known(.passageRewritten))
      content.leakHeldOver = state.headRevision
      _ = try DraftRecord.revise(rewritten, content, in: &transaction)
    }
    let sent = try await newer.pendingChanges(limit: Int.max).map(\.line)
    do {
      let old = try Self.openAtVersionThree(url)
      _ = try await old.write { transaction in
        _ = try Self.createNovelAsAnEarlierVersion(in: &transaction)
        _ = try DraftRecord(novel: Self.novel, chapter: 1, content: DraftContent(body: "The tide turns.", source: .known(.handEdited))).create(in: &transaction)
      }
      _ = try await old.applyRemote(sent)
      let held = try await SchemaFixture.document(rewritten, in: old)
      #expect(held.headRevision.flatMap { held.revisions[ExactString($0)]?.body["leak_hold"] } != nil)
    }

    let upgraded = try NovelForgeStore.open(at: url)
    #expect(try await upgraded.load(LibraryList.self).novels.map(\.novel.name) == ["Ember"])
    #expect(try await Self.review(of: 1, in: upgraded) == .needsReview)
    #expect(try await Self.review(of: 2, in: upgraded) == .contradiction)
  }

  @Test func shouldRefuseToReopenAVersionFourVaultWithTheVersionThreeSchema() throws {
    let url = try Self.temporaryVault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = try NovelForgeStore.open(at: url)
    #expect(throws: StoreError.self) { try Self.openAtVersionThree(url) }
  }

  @Test func shouldOpenAVaultWrittenAtVersionFourAtVersionFiveWithItsDataIntactAndTheSyncKernelWritable() async throws {
    let url = try Self.temporaryVault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let session = NovelForgeKey.chatSession(UUID())
    let message = NovelForgeKey.chatMessage(UUID())
    let replica = try Self.openAtVersionFour(url).replica
    do {
      let old = try Self.openAtVersionFour(url)
      _ = try await old.write { transaction in
        _ = try Self.createNovelAsAnEarlierVersion(in: &transaction)
        _ = try transaction.set(session, ["novel": Self.novelID, "title": "Openings", "mode": "auto", "status": "active", "removed": false])
        _ = try transaction.append(message, item: ["novel": Self.novelID, "session": .string(session.key.rawValue), "role": "user", "content": "Hello"])
      }
    }

    let upgraded = try NovelForgeStore.open(at: url)
    #expect(upgraded.replica == replica)
    #expect(try await upgraded.load(LibraryList.self).novels.map(\.novel.name) == ["Ember"])
    #expect(try await SchemaFixture.record(session, in: upgraded)[field: "title"]?.value == "Openings")
    guard case .appended(let appended)? = try await SchemaFixture.state(message, in: upgraded) else { throw SchemaFixtureError(description: "the message was lost") }
    #expect(appended.item["content"] == "Hello")
    let marker = EntityRef(kind: try #require(EntityKind("_schema_floor")), key: try #require(EntityKey("v-5")))
    try await SchemaFixture.set(marker, ["version": 5], in: upgraded)
    #expect(try await SchemaFixture.record(marker, in: upgraded)[field: "version"]?.value == 5)
  }

  @Test func shouldRefuseToReopenAVersionFiveVaultWithTheVersionFourSchema() throws {
    let url = try Self.temporaryVault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = try NovelForgeStore.open(at: url)
    #expect(throws: StoreError.self) { try Self.openAtVersionFour(url) }
  }

  @Test func shouldReopenAVersionFiveVaultAndKeepTheSyncMigrationsIdempotent() async throws {
    let url = try Self.temporaryVault()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let session = NovelForgeKey.chatSession(UUID())
    let first = try NovelForgeStore.open(at: url)
    try await SchemaFixture.set(session, ["novel": Self.novelID, "title": "Openings", "removed": false], in: first)
    let second = try NovelForgeStore.open(at: url)
    let third = try NovelForgeStore.open(at: url)
    #expect(first.replica == second.replica)
    #expect(second.replica == third.replica)
    #expect(try await SchemaFixture.record(session, in: third)[field: "title"]?.value == "Openings")
  }

  @Test func shouldKeepADecisionALaterVersionAddsOutOfTheRecordUntilTheUpgrade() async throws {
    let extended = NovelForgeSchema.entities.map { schema in
      guard schema.kind == NovelForgeKind.proposal.entityKind, case .record(var fields) = schema.shape else { return schema }
      fields["decision"] = .monotone(order: ["pending", "conflicted", "superseded", "discarded", "applied"])
      return EntitySchema(kind: schema.kind, shape: .record(fields: fields), syncClass: schema.syncClass)
    }
    let later = SyncKernelSchema.registry(version: NovelForgeSchema.version + 1, adding: extended + LedgerSchema.entities + JobSchema.entities)
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
