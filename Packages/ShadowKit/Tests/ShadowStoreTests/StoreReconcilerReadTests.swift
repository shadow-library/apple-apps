import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowStore

private let noteRef = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let otherNote = EntityRef(kind: Fixture.note, key: Fixture.key("k2"))
private let thirdNote = EntityRef(kind: Fixture.note, key: Fixture.key("k3"))
private let draftRef = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))
private let tagRef = EntityRef(kind: Fixture.tag, key: Fixture.key("t1"))

private let mirror = StoreMigration(identifier: "test.mirror.1") { db in
  try db.execute(sql: "CREATE TABLE mirror (scope INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, summary TEXT NOT NULL, PRIMARY KEY (scope, kind, key))")
}

private func summary(_ state: EntityState) -> String {
  func json(_ value: JSONValue) -> String { String(decoding: CanonicalJSON.encode(value), as: UTF8.self) }
  func fields(_ fields: [ExactString: FieldState]) -> String { fields.sorted { $0.key < $1.key }.map { "\($0.key)=\(json($0.value.value))" }.joined(separator: ";") }
  switch state {
  case .record(let record): return "record|\(fields(record.fields))"
  case .appended(let appended): return "appended|\(json(.object(appended.item)))"
  case .purged: return "purged"
  case .revisioned(let revisioned):
    let bodies = revisioned.revisions.values.sorted { $0.generation < $1.generation }.map { json($0.body) }.joined(separator: ",")
    return "revisioned|revisions=\(revisioned.revisions.count)|head=\(revisioned.headRevision ?? "-")|\(fields(revisioned.fields))|\(bodies)"
  }
}

private final class MirrorReconciler: StoreReconciler {
  private struct State {
    var failing = false
    var origins: [ChangeOrigin] = []
    var probes: [EntityState?] = []
  }

  private let registry: SchemaRegistry
  private let kinds: [EntityKind]
  private let rescan: Bool
  private let probe: EntityRef?
  private let state = Mutex(State())

  init(registry: SchemaRegistry, kinds: [EntityKind] = [Fixture.note, Fixture.draft, Fixture.tag], rescan: Bool = false, probe: EntityRef? = nil) {
    self.registry = registry
    self.kinds = kinds
    self.rescan = rescan
    self.probe = probe
  }

  var origins: [ChangeOrigin] { state.withLock { $0.origins } }
  var probes: [EntityState?] { state.withLock { $0.probes } }

  func fail(_ failing: Bool) {
    state.withLock { $0.failing = failing }
  }

  func reconcile(_ touched: [EntityRef], origin: ChangeOrigin, in database: Database) throws {
    let failing = state.withLock { state in
      state.origins.append(origin)
      return state.failing
    }
    let reads = ReadTransaction(database: database, registry: registry)
    if let probe {
      let read = try reads.state(of: probe)
      state.withLock { $0.probes.append(read) }
    }
    for scope in StateScope.allCases {
      if rescan {
        for kind in Set(touched.map(\.kind)).filter(kinds.contains) {
          try database.execute(sql: "DELETE FROM mirror WHERE scope = ? AND kind = ?", arguments: [scope.rawValue, kind.rawValue])
          for (ref, state) in try reads.states(ofKind: kind, scope: scope) { try write(ref, state, scope, in: database) }
        }
      } else {
        for ref in touched where kinds.contains(ref.kind) {
          guard let state = try reads.state(of: ref, scope: scope) else {
            try database.execute(sql: "DELETE FROM mirror WHERE scope = ? AND kind = ? AND key = ?", arguments: [scope.rawValue, ref.kind.rawValue, ref.key.rawValue])
            continue
          }
          try write(ref, state, scope, in: database)
        }
      }
    }
    if failing { throw ReconcilerFailure() }
  }

  func reset(in database: Database) throws {
    try database.execute(sql: "DELETE FROM mirror")
  }

  private func write(_ ref: EntityRef, _ state: EntityState, _ scope: StateScope, in database: Database) throws {
    try database.execute(
      sql: "INSERT OR REPLACE INTO mirror (scope, kind, key, summary) VALUES (?, ?, ?, ?)", arguments: [scope.rawValue, ref.kind.rawValue, ref.key.rawValue, summary(state)])
  }
}

private func mirrorRows(_ store: VaultStore) async throws -> [String: String] {
  try await store.read { transaction in
    let rows = try Row.fetchAll(transaction.database, sql: "SELECT scope, kind, key, summary FROM mirror")
    return Dictionary(uniqueKeysWithValues: rows.map { ("\($0["scope"] as Int)/\($0["kind"] as String)/\($0["key"] as String)", $0["summary"] as String) })
  }
}

private func expectedRows(_ store: VaultStore, kinds: [EntityKind] = [Fixture.note, Fixture.draft, Fixture.tag]) async throws -> [String: String] {
  try await store.read { transaction in
    var rows = [String: String]()
    for scope in StateScope.allCases {
      for kind in kinds {
        for (ref, state) in try transaction.states(ofKind: kind, scope: scope) { rows["\(scope.rawValue)/\(kind.rawValue)/\(ref.key.rawValue)"] = summary(state) }
      }
    }
    return rows
  }
}

private func open(_ reconciler: MirrorReconciler, _ registry: SchemaRegistry = Fixture.v2, at location: StoreLocation = .inMemory) throws -> VaultStore {
  try VaultStore.open(location, registry: registry, migrations: [mirror], wallClock: ManualClock().function, reconciler: reconciler)
}

private func revisions(_ count: Int, of ref: EntityRef) -> [Data] {
  (0..<count).map { index in
    let item = RevisionItem(parent: nil, body: .int(Int64(index)), created: Fixture.clock(Int64(index + 1), replica: 1), generation: Int64(index))
    return Fixture.revise(item, clock: item.created, entity: ref.kind, key: ref.key, head: false).canonicalBytes()
  }
}

private func remoteSet(_ ref: EntityRef, _ title: String, at wall: Int64) -> Data {
  let field = ref.kind == Fixture.tag ? "label" : "title"
  return Fixture.change(.set, ref.kind, ref.key, clock: Fixture.clock(wall, replica: 1), schema: 3, fields: [field: .string(title)]).canonicalBytes()
}

@Suite("VaultStore reconciler reads")
struct StoreReconcilerReadTests {
  @Test("should mirror the state read after a local write")
  func shouldMirrorLocalWrite() async throws {
    let reconciler = MirrorReconciler(registry: Fixture.v2)
    let store = try open(reconciler)
    _ = try await store.write { transaction in
      _ = try transaction.set(noteRef, ["title": "one", "status": "review"])
      _ = try transaction.revise(draftRef, body: "body")
    }
    let rows = try await mirrorRows(store)
    #expect(reconciler.origins == [.local])
    #expect(rows == (try await expectedRows(store)))
    let read = try #require(try await store.read { try $0.state(of: noteRef) })
    #expect(rows["0/note/k1"] == summary(read))
    #expect(rows["1/note/k1"] == summary(read))
    #expect(rows.count == 4)
  }

  @Test("should see the merged and retained state on a remote apply")
  func shouldMirrorRemoteApply() async throws {
    let reconciler = MirrorReconciler(registry: Fixture.v2)
    let store = try open(reconciler)
    _ = try await store.applyRemote([remoteSet(noteRef, "remote", at: 1)] + revisions(5, of: draftRef))
    let rows = try await mirrorRows(store)
    #expect(reconciler.origins == [.remote])
    #expect(rows == (try await expectedRows(store)))
    #expect(rows["0/draft/d1"]?.contains("revisions=3") == true)
    #expect(rows["0/draft/d1"]?.hasSuffix("|2,3,4") == true)
    #expect(rows["1/note/k1"] == nil)
  }

  @Test("should see both scopes after adoptRemote, retained")
  func shouldMirrorAdoptRemote() async throws {
    let reconciler = MirrorReconciler(registry: Fixture.v2)
    let store = try open(reconciler)
    _ = try await store.adoptRemote([remoteSet(noteRef, "adopted", at: 1)] + revisions(5, of: draftRef))
    let rows = try await mirrorRows(store)
    #expect(reconciler.origins == [.remote])
    #expect(rows == (try await expectedRows(store)))
    #expect(rows["0/note/k1"] == rows["1/note/k1"] && rows["0/note/k1"] != nil)
    #expect(rows["1/draft/d1"]?.contains("revisions=3") == true)
  }

  @Test("should read the own scope apart from the vault scope after a remote apply")
  func shouldReadOwnScope() async throws {
    let reconciler = MirrorReconciler(registry: Fixture.v2)
    let store = try open(reconciler)
    _ = try await store.write { transaction in try transaction.set(noteRef, ["title": "local"]) }
    _ = try await store.applyRemote([remoteSet(noteRef, "remote", at: 5_000)])
    let rows = try await mirrorRows(store)
    #expect(rows == (try await expectedRows(store)))
    #expect(rows["0/note/k1"]?.contains("\"remote\"") == true)
    #expect(rows["1/note/k1"]?.contains("\"local\"") == true)
  }

  @Test("should list every entity of the kind, purged ones as purged, through states(ofKind:)")
  func shouldListKindInsideReconciler() async throws {
    let reconciler = MirrorReconciler(registry: Fixture.v2, kinds: [Fixture.note], rescan: true)
    let store = try open(reconciler)
    _ = try await store.write { transaction in
      for ref in [noteRef, otherNote, thirdNote] { _ = try transaction.set(ref, ["title": "t"]) }
    }
    _ = try await store.write { transaction in try transaction.purge(otherNote) }
    let rows = try await mirrorRows(store)
    #expect(rows == (try await expectedRows(store, kinds: [Fixture.note])))
    #expect(rows["0/note/k2"] == "purged")
    #expect(rows.keys.filter { $0.hasPrefix("0/note/") }.count == 3)
  }

  @Test("should end equal to a mirror rebuilt from scratch after a registry upgrade at open")
  func shouldMirrorUpgrade() async throws {
    let directory = TemporaryDirectory()
    let first = MirrorReconciler(registry: Fixture.v1, kinds: [Fixture.note, Fixture.draft])
    let store = try open(first, Fixture.v1, at: .file(directory.storeURL))
    _ = try await store.applyRemote([remoteSet(noteRef, "remote", at: 1), remoteSet(tagRef, "label", at: 2)] + revisions(3, of: draftRef))
    let before = try await mirrorRows(store)
    #expect(before["0/draft/d1"]?.contains("revisions=3") == true)
    let upgrade = MirrorReconciler(registry: Fixture.vStrict)
    let upgraded = try open(upgrade, Fixture.vStrict, at: .file(directory.storeURL))
    let rows = try await mirrorRows(upgraded)
    #expect(upgrade.origins == [.upgrade])
    #expect(rows == (try await expectedRows(upgraded)))
    #expect(rows["0/draft/d1"]?.contains("revisions=2") == true)
    #expect(rows["0/tag/t1"] != nil)
  }

  @Test("should end equal to a mirror rebuilt from scratch after a rebuild remint")
  func shouldMirrorRemint() async throws {
    let reconciler = MirrorReconciler(registry: Fixture.v2)
    let store = try open(reconciler)
    _ = try await store.applyRemote([remoteSet(otherNote, "remote", at: 1)])
    _ = try await store.write { transaction in try transaction.set(noteRef, ["title": "local"]) }
    #expect(try await mirrorRows(store)["0/note/k2"] != nil)
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .rebuild)
    let rows = try await mirrorRows(store)
    #expect(rows == (try await expectedRows(store)))
    #expect(rows["0/note/k2"] == nil)
    #expect(rows["0/note/k1"] != nil)
    #expect(reconciler.origins == [.remote, .local, .local])
  }

  @Test("should roll the mirror back with the transaction when the reconciler throws")
  func shouldRollBack() async throws {
    let reconciler = MirrorReconciler(registry: Fixture.v2)
    let store = try open(reconciler)
    _ = try await store.write { transaction in try transaction.set(noteRef, ["title": "kept"]) }
    let before = try await mirrorRows(store)
    let image = try await StoreImage(store)
    reconciler.fail(true)
    let error = await #expect(throws: StoreError.self) {
      try await store.write { transaction in try transaction.set(otherNote, ["title": "lost"]) }
    }
    guard case .reconcilerFailed = error else { throw StoreTestFailure.unexpectedState }
    #expect(try await mirrorRows(store) == before)
    #expect(try await StoreImage(store) == image)
  }

  @Test("should read a kind the registry does not declare as a normal read transaction does")
  func shouldReadUndeclaredKind() async throws {
    let reconciler = MirrorReconciler(registry: Fixture.v1, kinds: [Fixture.note], probe: tagRef)
    let store = try open(reconciler, Fixture.v1)
    _ = try await store.applyRemote([remoteSet(tagRef, "foreign", at: 1)])
    _ = try await store.write { transaction in try transaction.set(noteRef, ["title": "one"]) }
    let normal = try await store.read { try $0.state(of: tagRef) }
    #expect(normal == nil)
    #expect(reconciler.probes == [nil])
    #expect(try await store.read { try $0.states(ofKind: Fixture.tag) }.isEmpty)
    #expect(try await store.loadState(.vault).foreign.count == 1)
  }
}
