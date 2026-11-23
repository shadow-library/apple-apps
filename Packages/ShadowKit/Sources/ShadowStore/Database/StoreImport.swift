import Foundation
import GRDB
import ShadowCore

/// One store's part of an import. `entities` are written in the order given, each with a new clock, so items keep the order they are listed in. `kinds`
/// are what counts as the store's data: the import refuses a store holding any entity of them, and an entity of any
/// other kind. `alongside` writes the caller's own tables in the same transaction.
public struct StoreImport: Sendable {
  public let store: VaultStore
  public let entities: [ImportedEntity]
  public let kinds: Set<EntityKind>
  public let alongside: @Sendable (Database) throws -> Void

  public init(store: VaultStore, entities: [ImportedEntity], kinds: Set<EntityKind>, alongside: @escaping @Sendable (Database) throws -> Void = { _ in }) {
    self.store = store
    self.entities = entities
    self.kinds = kinds
    self.alongside = alongside
  }
}

extension VaultStore {
  /// The one way to write entities as an export held them, and only into stores that hold none of their data yet. Each store's import is one transaction
  /// that stays open, its settlement done, until every later store's has run, so a refusal or failure anywhere leaves every store as it was. They commit
  /// from the last store to the first, so the first store gains its data last; only a failure of a commit itself, after a later store committed, can
  /// leave the stores apart.
  public static func importEntities(_ imports: [StoreImport]) async throws(StoreError) -> [[ChangeRecord]] {
    guard let first = imports.first else { return [] }
    guard Set(imports.map { ObjectIdentifier($0.store) }).count == imports.count else { throw .importRefused("a store is named twice") }
    for part in imports {
      for entity in part.entities {
        guard part.kinds.contains(entity.ref.kind) else { throw .importRefused("kind \(entity.ref.kind) is not among the kinds this store imports") }
        if let refusal = part.store.registry.importRefusal(of: entity) { throw .importRefused(refusal) }
      }
    }
    let rest = imports.dropFirst()
    return try await first.store.writing { db in try importing(first, in: db, then: rest) }
  }

  private static func importing(_ part: StoreImport, in db: Database, then rest: ArraySlice<StoreImport>) throws -> [[ChangeRecord]] {
    let changes = try part.store.transacting(in: db) { transaction in
      guard try !transaction.holdsEntities(ofKinds: part.kinds) else { throw StoreError.importRefused("the store already holds data") }
      var changes = [ChangeRecord]()
      for entity in part.entities { changes += try transaction.importEntity(entity) }
      try part.alongside(db)
      return changes
    }
    guard let next = rest.first else { return [changes] }
    return [changes] + (try next.store.writingNested { db in try importing(next, in: db, then: rest.dropFirst()) })
  }
}

extension ReadTransaction {
  /// Whether any entity of these kinds has state, a tombstone or a record this build cannot read, in either scope.
  public func holdsEntities(ofKinds kinds: some Sequence<EntityKind>) throws(StoreError) -> Bool {
    try EntityPresence.holds(kinds, in: database)
  }
}

extension WriteTransaction {
  /// Whether any entity of these kinds has state, a tombstone or a record this build cannot read, in either scope.
  public func holdsEntities(ofKinds kinds: some Sequence<EntityKind>) throws(StoreError) -> Bool {
    try EntityPresence.holds(kinds, in: database)
  }

  mutating func importEntity(_ entity: ImportedEntity) throws(StoreError) -> [ChangeRecord] {
    if let refusal = registry.importRefusal(of: entity) { throw .importRefused(refusal) }
    let ref = entity.ref
    guard try !EntityPresence.holds(ref, in: database) else { throw .importRefused("\(ref.kind)/\(ref.key) is held already") }
    switch entity {
    case .record(_, let fields):
      return [try set(ref, fields)]
    case .appended(_, let item):
      return [try append(ref, item: item)]
    case .revisioned(_, let fields, let head, let revisions):
      var changes = fields.isEmpty ? [] : [try set(ref, fields)]
      var written = [ExactString: String]()
      for revision in revisions.sorted(by: { ($0.generation, ExactString($0.id)) < ($1.generation, ExactString($1.id)) }) {
        let parent = revision.parent.map { written[ExactString($0)] ?? $0 }
        let item = RevisionItem(parent: parent, body: revision.body, created: revision.created ?? clock.now(), generation: revision.generation)
        written[ExactString(revision.id)] = item.id
        let isHead = head.map { ExactString($0) == ExactString(revision.id) } ?? false
        changes.append(
          try commit(.revise(id: ids.next(), clock: clock.now(), schema: registry.version, entity: ref.kind, key: ref.key, item: item, head: isHead)))
      }
      return changes
    }
  }
}

private enum EntityPresence {
  static func holds(_ kinds: some Sequence<EntityKind>, in database: Database) throws(StoreError) -> Bool {
    for kind in kinds {
      if try holds("kind = ?", [kind.rawValue], in: database) { return true }
    }
    return false
  }

  static func holds(_ ref: EntityRef, in database: Database) throws(StoreError) -> Bool {
    try holds("kind = ? AND key = ?", [ref.kind.rawValue, ref.key.rawValue], in: database)
  }

  private static func holds(_ filter: String, _ arguments: StatementArguments, in database: Database) throws(StoreError) -> Bool {
    let scopes = StateScope.allCases.map { String($0.rawValue) }.joined(separator: ", ")
    return try StoreError.wrapping {
      try ["field_state", "appended_item", "revision", "tombstone", "foreign_record"].contains { table in
        try database.storeFetchOne("SELECT 1 FROM \(table) WHERE scope IN (\(scopes)) AND \(filter) LIMIT 1", arguments) != nil
      }
    }
  }
}
