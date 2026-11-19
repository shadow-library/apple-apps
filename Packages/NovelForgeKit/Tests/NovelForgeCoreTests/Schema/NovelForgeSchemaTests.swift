import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("NovelForgeSchema")
struct NovelForgeSchemaTests {
  private static let frozenVersions = [1, 2, 3, 4]

  private static func frozenPath(_ version: Int) -> String { "schema/registry-v\(version).json" }

  @Test func shouldMatchTheFrozenRegistryDescription() throws {
    let frozen = try ReferenceFixture.data(Self.frozenPath(NovelForgeSchema.version))
    let current = SchemaFixture.registry.canonicalDescription()
    #expect(
      current == frozen,
      """
      NovelForgeSchema no longer matches Fixtures/\(Self.frozenPath(NovelForgeSchema.version)). A synced kind's shape, a field's rule, a mark or a retention \
      limit can never change once shipped, and a kind or field can never be removed. To add kinds, fields, marks or monotone values, raise \
      NovelForgeSchema.version, save the new canonical description as Fixtures/schema/registry-v<new version>.json, keep every earlier file, \
      and add the new version to frozenVersions.
      """)
  }

  @Test func shouldStayCompatibleWithEveryFrozenRegistry() throws {
    #expect(Self.frozenVersions.last == NovelForgeSchema.version)
    for version in Self.frozenVersions {
      let frozen = try SchemaRegistry(canonicalDescription: try ReferenceFixture.data(Self.frozenPath(version)))
      #expect(frozen.version == version)
      #expect(SchemaFixture.registry.incompatibilities(with: frozen) == [], "the schema cannot carry version \(version) additively")
    }
  }

  @Test func shouldReportADeliberatelyChangedRuleAsIncompatible() throws {
    let registry = SchemaFixture.registry
    #expect(registry.incompatibilities(with: registry) == [])
    let changed = NovelForgeSchema.entities.map { schema in
      guard schema.kind == NovelForgeKind.finalChapter.entityKind, case .revisioned(var fields, let marks, let retention) = schema.shape else { return schema }
      fields["canon"] = .register
      return EntitySchema(kind: schema.kind, shape: .revisioned(fields: fields, marks: marks, retention: retention), syncClass: schema.syncClass)
    }
    let problems = SchemaRegistry(version: NovelForgeSchema.version + 1, entities: changed + LedgerSchema.entities + JobSchema.entities).incompatibilities(with: registry)
    #expect(problems == ["field nf_final_chapter.canon changed rule from first writer wins to register"])
  }

  @Test func shouldAcceptOneWriteAndReadOfEveryKind() async throws {
    let store = try SchemaFixture.store()
    let natural = try SchemaFixture.naturalKeys(novel: SchemaFixture.novel)
    for key in natural {
      try await SchemaFixture.set(key.ref, ["natural_key": key.stored], in: store)
      let schema = try #require(SchemaFixture.registry[key.ref.kind])
      if case .revisioned = schema.shape { _ = try await SchemaFixture.revise(key.ref, ["text": "first"], in: store) }
      let state = try #require(try await SchemaFixture.state(key.ref, in: store))
      #expect(try NovelForgeKey(reading: state, of: key.ref) == key)
    }
    let novel = NovelForgeKey.novel(SchemaFixture.novel)
    try await SchemaFixture.set(novel, ["name": "The Gate", "archived": false], in: store)
    #expect(try await SchemaFixture.record(novel, in: store)[field: "name"]?.value == "The Gate")
    let session = NovelForgeKey.chatSession(UUID())
    try await SchemaFixture.set(session, ["title": "Openings", "auto_title": "Openings", "removed": false], in: store)
    #expect(try await SchemaFixture.record(session, in: store)[field: "title"]?.value == "Openings")
    let proposal = NovelForgeKey.proposal(UUID())
    try await SchemaFixture.set(proposal, ["card": ["kind": "chat"], "decision": "pending"], in: store)
    #expect(try await SchemaFixture.record(proposal, in: store)[field: "decision"]?.value == "pending")
    let items = [
      NovelForgeKey.approval(UUID()), NovelForgeKey.notebookEntry(UUID()), NovelForgeKey.notebookWithdrawal(UUID()), NovelForgeKey.chatMessage(UUID()),
      NovelForgeKey.chatSummary(UUID()), NovelForgeKey.chapterReview(UUID()), NovelForgeKey.finalizeReview(UUID()), NovelForgeKey.refreshReport(UUID()),
    ]
    for ref in items {
      _ = try await store.write { transaction in try transaction.append(ref, item: ["novel": .string(SchemaFixture.novel.uuidString.lowercased())]) }
      guard case .appended? = try await SchemaFixture.state(ref, in: store) else { throw SchemaFixtureError(description: "\(ref.kind) was not appended") }
    }
    let written = Set(natural.map(\.kind) + [.novel, .chatSession, .proposal] + items.compactMap { NovelForgeKind($0.kind) })
    #expect(written == Set(NovelForgeKind.allCases))
  }

  @Test func shouldRefuseAKindOutsideTheList() async throws {
    let store = try SchemaFixture.store()
    let outside = try #require(EntityKind(NovelForge.kindPrefix + "job"))
    let ref = EntityRef(kind: outside, key: EntityKey(uuid: UUID()))
    await #expect(throws: StoreError.self) { try await SchemaFixture.set(ref, ["title": "Chat"], in: store) }
  }

  @Test func shouldRefuseTheKindsLeftOutOfVersionOne() async throws {
    let store = try SchemaFixture.store()
    for name in ["entity_alias", "entity_relation", "character_state", "character_event", "world_fact", "finalize_order"] {
      let kind = try #require(EntityKind(NovelForge.kindPrefix + name))
      #expect(NovelForgeKind(kind) == nil)
      let ref = EntityRef(kind: kind, key: EntityKey.natural(scope: SchemaFixture.novel.uuidString.lowercased(), kind: kind, components: ["aria"]))
      await #expect(throws: StoreError.self) { try await SchemaFixture.set(ref, ["removed": false], in: store) }
    }
  }

  @Test func shouldRefuseAFieldOutsideAKind() async throws {
    let store = try SchemaFixture.store()
    let ref = NovelForgeKey.volume(novel: SchemaFixture.novel, key: "book-one")
    await #expect(throws: StoreError.self) { try await SchemaFixture.set(ref, ["state": "active"], in: store) }
  }

  @Test func shouldNameEveryKindInsideTheNovelForgePrefixAndOutsideTheKernelReservedPrefix() {
    #expect(NovelForgeSchema.entities.count == NovelForgeKind.allCases.count)
    #expect(Set(NovelForgeSchema.entities.map(\.kind)) == Set(NovelForgeKind.allCases.map(\.entityKind)))
    for kind in NovelForgeKind.allCases {
      #expect(kind.rawValue.hasPrefix(NovelForge.kindPrefix))
      #expect(!kind.rawValue.hasPrefix("_"))
      #expect(NovelForgeKind(kind.entityKind) == kind)
    }
  }

  @Test func shouldSyncEveryKindAsGeneral() {
    #expect(NovelForgeSchema.entities.allSatisfy { $0.syncClass == .general })
  }

  @Test func shouldKeepTheNewestFiftyRevisionsOfEveryDocumentAsTheReferenceDraftHistoryDoes() {
    for schema in NovelForgeSchema.entities {
      guard case .revisioned(_, _, let retention) = schema.shape else { continue }
      #expect(retention == .keepNewest(50), "\(schema.kind) keeps \(retention)")
    }
    #expect(NovelForgeSchema.revisionLimit == 50)
  }
}
