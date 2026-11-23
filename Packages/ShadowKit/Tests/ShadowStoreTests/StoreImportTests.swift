import Foundation
import GRDB
import ShadowCore
import Testing

@testable import ShadowStore

@Suite("VaultStore import", TestTimeLimit.standard)
struct StoreImportTests {
  private static let kinds: Set<EntityKind> = [Fixture.note, Fixture.message, Fixture.draft, Fixture.outline]
  private static let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
  private static let message = EntityRef(kind: Fixture.message, key: Fixture.key("m1"))
  private static let draft = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))

  @Test("should import records, items and revisions as held, keeping revision ids, generations and a head that is not the newest")
  func shouldImportExactly() async throws {
    let source = try await Self.filledStore()
    let entities = try await Self.exported(source, keepingCreated: true)
    let target = try StoreFixture.open()

    let changes = try await VaultStore.importEntities([StoreImport(store: target, entities: entities, kinds: Self.kinds)])

    #expect(try await Self.exported(target, keepingCreated: true) == entities)
    let original = try await source.read { transaction in try transaction.state(of: Self.draft) }
    let restored = try await target.read { transaction in try transaction.state(of: Self.draft) }
    guard case .revisioned(let before)? = original, case .revisioned(let after)? = restored else { throw ImportFailure("the draft is not revisioned") }
    #expect(after.revisions == before.revisions && after.headRevision == before.headRevision)
    #expect(after.headRevision != after.revisions.max { $0.value.generation < $1.value.generation }?.key.value, "the head is an older revision")
    #expect(try await target.allPending.count == changes[0].count, "every imported change waits for upload")
  }

  @Test("should write revisions without their creation clock under new ids that their children and the head follow")
  func shouldRemapRevisionsWithoutCreation() async throws {
    let source = try await Self.filledStore()
    let entities = try await Self.exported(source, keepingCreated: false)
    let target = try StoreFixture.open()

    _ = try await VaultStore.importEntities([StoreImport(store: target, entities: entities, kinds: Self.kinds)])

    let original = try await source.read { transaction in try transaction.state(of: Self.draft) }
    let restored = try await target.read { transaction in try transaction.state(of: Self.draft) }
    guard case .revisioned(let before)? = original, case .revisioned(let after)? = restored else { throw ImportFailure("the draft is not revisioned") }
    #expect(Set(after.revisions.keys).isDisjoint(with: before.revisions.keys))
    #expect(after.revisions.values.map(\.generation).sorted() == before.revisions.values.map(\.generation).sorted())
    let head = try #require(after.headRevision.flatMap { after.revisions[ExactString($0)] })
    let oldHead = try #require(before.headRevision.flatMap { before.revisions[ExactString($0)] })
    #expect(head.body == oldHead.body && head.generation == oldHead.generation)
    for item in after.revisions.values where item.generation > 0 {
      #expect(item.parent.map { after.revisions[ExactString($0)] != nil } == true, "a child names its parent's new id")
    }
  }

  @Test("should refuse a store that holds data of its kinds and write nothing to any store")
  func shouldRefuseAHeldStore() async throws {
    let held = try await Self.filledStore()
    let pending = try await held.allPending.count
    let empty = try StoreFixture.open()
    let entities = try await Self.exported(held, keepingCreated: true)

    let error = await #expect(throws: StoreError.self) {
      _ = try await VaultStore.importEntities([
        StoreImport(store: empty, entities: entities, kinds: Self.kinds), StoreImport(store: held, entities: [], kinds: Self.kinds),
      ])
    }

    guard case .importRefused? = error else { throw ImportFailure("expected an import refusal, got \(String(describing: error))") }
    #expect(try await empty.allPending.isEmpty)
    #expect(try await !empty.read { transaction in try transaction.holdsEntities(ofKinds: Self.kinds) })
    #expect(try await held.allPending.count == pending)
  }

  @Test("should leave the first two stores empty when the third store's import fails")
  func shouldRollBackEveryStore() async throws {
    let entities = try await Self.exported(try await Self.filledStore(), keepingCreated: true)
    let stores = try (0..<3).map { _ in try StoreFixture.open() }
    let tooLarge = ImportedEntity.record(Self.note, fields: ["title": .string(String(repeating: "x", count: VaultStore.maximumChangeBytes))])

    let error = await #expect(throws: StoreError.self) {
      _ = try await VaultStore.importEntities([
        StoreImport(store: stores[0], entities: entities, kinds: Self.kinds), StoreImport(store: stores[1], entities: entities, kinds: Self.kinds),
        StoreImport(store: stores[2], entities: [tooLarge], kinds: Self.kinds),
      ])
    }

    guard case .changeTooLarge? = error else { throw ImportFailure("expected the third store to fail, got \(String(describing: error))") }
    for store in stores {
      #expect(try await store.allPending.isEmpty)
      #expect(try await !store.read { transaction in try transaction.holdsEntities(ofKinds: Self.kinds) })
    }
  }

  @Test("should roll the caller's own tables back with the import")
  func shouldRollBackTheCallersTables() async throws {
    let first = try StoreFixture.open()
    let second = try StoreFixture.open()
    let refused = ImportedEntity.record(Self.note, fields: ["title": .string(String(repeating: "x", count: VaultStore.maximumChangeBytes))])

    await #expect(throws: StoreError.self) {
      _ = try await VaultStore.importEntities([
        StoreImport(store: first, entities: [], kinds: Self.kinds) { database in try database.execute(sql: "CREATE TABLE caller_table (id INTEGER)") },
        StoreImport(store: second, entities: [refused], kinds: Self.kinds),
      ])
    }

    #expect(try await !first.read { transaction in try transaction.database.tableExists("caller_table") })
  }

  @Test("should refuse an entity its registry does not take as given before writing anything")
  func shouldRefuseUndeclaredContent() async throws {
    let created = Fixture.clock(1)
    let item = RevisionItem(parent: nil, body: ["text": "a"], created: created, generation: 0)
    let refused: [ImportedEntity] = [
      .record(Self.note, fields: ["colour": "red"]),
      .record(Self.note, fields: ["status": "unknown"]),
      .record(Self.note, fields: [:]),
      .appended(EntityRef(kind: Fixture.note, key: Fixture.key("k2")), item: ["text": "a"]),
      .record(EntityRef(kind: Fixture.tag, key: Fixture.key("t1")), fields: ["label": "a"]),
      .revisioned(Self.draft, fields: [:], head: "v:missing", revisions: []),
      .revisioned(Self.draft, fields: [:], head: nil, revisions: [ImportedRevision(id: "v:other", parent: nil, body: item.body, generation: 0, created: created)]),
      .revisioned(
        Self.draft, fields: [:], head: nil,
        revisions: [
          ImportedRevision(id: item.id, parent: nil, body: item.body, generation: 0, created: created),
          ImportedRevision(id: "v:late", parent: item.id, body: ["text": "b"], generation: 1, created: nil),
        ]),
    ]
    for entity in refused {
      let store = try StoreFixture.open()
      let error = await #expect(throws: StoreError.self) {
        _ = try await VaultStore.importEntities([StoreImport(store: store, entities: [entity], kinds: Self.kinds)])
      }
      guard case .importRefused? = error else { throw ImportFailure("expected a refusal of \(entity), got \(String(describing: error))") }
      #expect(try await store.allPending.isEmpty)
    }
  }

  @Test("should refuse the same store named twice")
  func shouldRefuseAStoreNamedTwice() async throws {
    let store = try StoreFixture.open()
    let error = await #expect(throws: StoreError.self) {
      _ = try await VaultStore.importEntities([StoreImport(store: store, entities: [], kinds: Self.kinds), StoreImport(store: store, entities: [], kinds: Self.kinds)])
    }
    guard case .importRefused? = error else { throw ImportFailure("expected an import refusal, got \(String(describing: error))") }
  }

  private static func filledStore() async throws -> VaultStore {
    let store = try StoreFixture.open()
    try await store.write { transaction in
      _ = try transaction.set(note, ["title": "Kept", "status": "review", "origin": "phone"])
      _ = try transaction.append(message, item: ["text": "hello", "count": 3])
      let first = try transaction.revise(draft, body: ["text": "one"]).revision
      _ = try transaction.revise(draft, body: ["text": "two"])
      _ = try transaction.revise(draft, body: ["text": "three"])
      _ = try transaction.reassert(draft, revision: first, head: true)
      _ = try transaction.set(draft, ["title": "Draft"])
    }
    return store
  }

  private static func exported(_ store: VaultStore, keepingCreated: Bool) async throws -> [ImportedEntity] {
    try await store.read { transaction in
      try kinds.sorted().flatMap { kind in
        try transaction.states(ofKind: kind).compactMap { ref, state -> ImportedEntity? in
          switch state {
          case .purged: return nil
          case .record(let record): return .record(ref, fields: Dictionary(uniqueKeysWithValues: record.fields.map { ($0.key.value, $0.value.value) }))
          case .appended(let appended): return .appended(ref, item: appended.item)
          case .revisioned(let document):
            let revisions = document.revisions.map { id, item in
              ImportedRevision(id: id.value, parent: item.parent, body: item.body, generation: item.generation, created: keepingCreated ? item.created : nil)
            }
            return .revisioned(
              ref, fields: Dictionary(uniqueKeysWithValues: document.fields.map { ($0.key.value, $0.value.value) }), head: document.headRevision,
              revisions: revisions.sorted { ($0.generation, $0.id) < ($1.generation, $1.id) })
          }
        }
      }
    }
  }
}

private struct ImportFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
