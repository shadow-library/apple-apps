import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let message = EntityRef(kind: Fixture.message, key: Fixture.key("m1"))
private let draft = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))
private let tag = EntityRef(kind: Fixture.tag, key: Fixture.key("t1"))

private let additivePairs = [
  (Fixture.v1, Fixture.vMid), (Fixture.vMid, Fixture.v2), (Fixture.v1, Fixture.v2), (Fixture.v2, Fixture.vInsert), (Fixture.v1, Fixture.vInsert),
  (Fixture.v2, Fixture.vStrict), (Fixture.v1, Fixture.vStrict),
]

private func registryVersion(_ store: VaultStore) async throws -> Int? {
  try await store.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT registry_version FROM kernel_state") }
}

private func storedDescription(_ store: VaultStore) async throws -> Data? {
  try await store.read { transaction in try Data.fetchOne(transaction.database, sql: "SELECT registry FROM kernel_state") }
}

private func plantDescription(_ bytes: Data, in store: VaultStore) async throws {
  try await store.write { transaction in try transaction.database.execute(sql: "UPDATE kernel_state SET registry = ?", arguments: [bytes]) }
}

private let plantedDescriptions: [(name: String, bytes: Data)] = [
  ("an empty description", Data()),
  ("a description that is not JSON", Data("garbage".utf8)),
  ("a description of another version", Fixture.v2.canonicalDescription()),
]

private func upgraded(_ state: VaultState, _ registry: SchemaRegistry) throws -> (reinterpreted: VaultState, retained: VaultState) {
  var reinterpreted = state
  try reinterpreted.reinterpretForeign(registry: registry)
  return (reinterpreted, reinterpreted.retained(registry: registry))
}

private func upgradeTouched(_ vault: VaultState, _ registry: SchemaRegistry) throws -> [EntityRef] {
  let (reinterpreted, retained) = try upgraded(vault, registry)
  let resplit = vault.foreign.filter { record in
    let interpretation = registry.interpretation(of: record)
    return interpretation.state != nil && interpretation.foreign?.canonicalBytes() != record.canonicalBytes()
  }
  let pruned = retained.refs.filter { retained.state(of: $0) != reinterpreted.state(of: $0) }
  return Set(resplit.map(\.ref) + pruned).sorted()
}

private struct Filled {
  var local: [ChangeRecord] = []
  var planted: [ChangeRecord] = []
  var remote: [ChangeRecord] = []
  var opaque: [Data] = []
}

private func fill(_ store: VaultStore, _ generator: inout SeededGenerator) async throws -> Filled {
  var factory = ChangeFactory()
  var known = [EntityRef: [String]]()
  var filled = Filled()
  for _ in 0..<generator.int(in: 1...4) {
    switch generator.int(in: 0...4) {
    case 0, 1:
      let records = factory.changes(&generator, count: 0...12)
      let opaque = (0..<generator.int(in: 0...1)).map { _ in generator.opaqueLine() }
      _ = try await store.applyRemote(Remote.lines(records, opaque: opaque, &generator))
      filled.remote += records
      filled.opaque += opaque
    case 2:
      let records = (0..<generator.int(in: 1...3)).map { _ in factory.foreign(&generator) }
      try await store.apply(records, scope: .own)
      filled.planted += records
    default:
      let result = try await runLocalLeniently((0..<generator.int(in: 1...8)).map { _ in LocalOperation.random(&generator) }, in: store, known: known)
      filled.local += result.records
      known = result.known
    }
  }
  return filled
}

private func registry(note: EntityShape? = nil, noteClass: SyncClass = .general, draftMarks: [String] = ["approved"], message: Bool = true) -> SchemaRegistry {
  let declared = EntityShape.record(fields: ["title": .register, "status": .monotone(order: Fixture.statusOrder), "origin": .firstWriterWins])
  var entities = [
    EntitySchema(kind: Fixture.note, shape: note ?? declared, syncClass: noteClass),
    EntitySchema(kind: Fixture.draft, shape: .revisioned(fields: ["title": .register], marks: draftMarks, retention: .keepNewest(3)), syncClass: .general),
    EntitySchema(kind: Fixture.outline, shape: .revisioned(fields: [:], marks: [], retention: .keepNewest(1)), syncClass: .general),
  ]
  if message { entities.append(EntitySchema(kind: Fixture.message, shape: .appended, syncClass: .general)) }
  return SchemaRegistry(version: 9, entities: entities)
}

private let refusals: [(name: String, registry: SchemaRegistry)] = [
  ("a removed kind", registry(message: false)),
  ("a changed shape", registry(note: .appended)),
  ("a removed field", registry(note: .record(fields: ["title": .register, "origin": .firstWriterWins]))),
  ("a removed mark", registry(draftMarks: [])),
  ("a value its rule no longer admits", registry(note: .record(fields: ["title": .register, "origin": .firstWriterWins, "status": .monotone(order: ["draft"])]))),
]

private let registryOnlyRefusals: [(name: String, registry: SchemaRegistry)] = [
  (
    "a rule change whose stored values are still admitted",
    registry(note: .record(fields: ["title": .firstWriterWins, "status": .monotone(order: Fixture.statusOrder), "origin": .firstWriterWins]))
  ),
  (
    "a record kind declared revisioned while it holds only fields",
    registry(note: .revisioned(fields: ["title": .register, "status": .monotone(order: Fixture.statusOrder), "origin": .firstWriterWins], marks: [], retention: .keepAll))
  ),
  ("a changed sync class", registry(noteClass: .activity)),
]

private struct RowPlant: Sendable, CustomTestStringConvertible {
  let name: String
  let sql: String
  let arguments: StatementArguments
  let reason: String

  var testDescription: String { name }
}

private let rowPlants: [RowPlant] = [
  RowPlant(
    name: "rows of an undeclared kind", sql: "INSERT INTO field_state VALUES (0, 'ghost', 'g1', 0, ?, ?, ?)",
    arguments: [Stored.name("title"), CanonicalJSON.encode("t"), Fixture.clock(1).description], reason: "kind ghost is no longer declared"),
  RowPlant(
    name: "rows of the wrong shape", sql: "INSERT INTO appended_item VALUES (1, 'note', 'k9', CAST('{}' AS BLOB), ?)", arguments: [Fixture.clock(1).description],
    reason: "note/k9 is appended but the kind is declared record"),
  RowPlant(
    name: "an undeclared field", sql: "INSERT INTO field_state VALUES (0, 'note', 'k1', 0, ?, ?, ?)",
    arguments: [Stored.name("bogus"), CanonicalJSON.encode(true), Fixture.clock(1).description], reason: "field note.bogus is no longer declared"),
  RowPlant(
    name: "a value its rule does not admit", sql: "UPDATE field_state SET value = ? WHERE scope = 1 AND kind = 'note' AND name = ?",
    arguments: [CanonicalJSON.encode("nonsense"), Stored.name("status")],
    reason: "field note.status holds a value that monotone [draft, review, final, archived] does not admit"),
  RowPlant(
    name: "an undeclared mark", sql: "INSERT INTO field_state VALUES (0, 'draft', 'd1', 2, ?, ?, ?)",
    arguments: [Stored.name("bogus"), CanonicalJSON.encode("v:00"), Fixture.clock(1).description], reason: "mark draft.bogus is no longer declared"),
]

private func rawImage(_ store: VaultStore) async throws -> [String] {
  try await store.read { transaction in
    try (KernelSchema.stateTables + ["kernel_state", "change_log"]).flatMap { table in
      try Row.fetchAll(transaction.database, sql: "SELECT * FROM \(table)").map { "\(table) \($0)" }.sorted()
    }
  }
}

private func seededFile(_ directory: TemporaryDirectory) async throws -> VaultStore {
  let store = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1)
  _ = try await store.write { transaction in
    _ = try transaction.set(note, ["title": "t", "status": "final"])
    _ = try transaction.append(message, item: ["text": "x"])
    _ = try transaction.revise(draft, body: "b", marks: ["approved"])
  }
  _ = try await store.applyRemote(
    [Fixture.change(.set, tag.kind, tag.key, clock: Fixture.clock(1, replica: 1), fields: ["label": "foreign"]).canonicalBytes(), Data("{\"kind\": \"set\"}".utf8)])
  return store
}

@Suite("VaultStore registry upgrade")
struct StoreUpgradeTests {
  @Test("should equal the reference reinterpreted and retained under the newer registry in both scopes, once")
  func shouldUpgradeLikeTheReference() async throws {
    try await forAll(iterations: 150, seed: 0x0A_7E) { generator in
      let (older, newer) = generator.pick(from: additivePairs)
      let directory = TemporaryDirectory()
      let olderStore = try StoreFixture.open(older, at: .file(directory.storeURL))
      let filled = try await fill(olderStore, &generator)
      let vault = Remote.reference(filled.local + filled.remote, opaque: filled.opaque, older)
      let own = Remote.reference(filled.local + filled.planted, older)
      let reconciler = RecordingReconciler()
      let store = try VaultStore.open(.file(directory.storeURL), registry: newer, reconciler: reconciler)
      let expectedVault = try upgraded(vault, newer).retained
      let expectedOwn = try upgraded(own, newer).retained
      try #require(try await store.loadState(.vault) == expectedVault)
      try #require(try await store.loadState(.vault).digest == expectedVault.digest)
      try #require(try await store.loadState(.own) == expectedOwn)
      let touched = try upgradeTouched(vault, newer)
      try #require(reconciler.calls.map(\.touched) == (touched.isEmpty ? [] : [touched]))
      try #require(reconciler.calls.allSatisfy { $0.origin == .upgrade })
      try #require(try await registryVersion(store) == newer.version)
      try #require(try await storedDescription(store) == newer.canonicalDescription())
      reconciler.clear()
      let reopened = try VaultStore.open(.file(directory.storeURL), registry: newer, reconciler: reconciler)
      try #require(try await reopened.loadState(.vault).digest == expectedVault.digest)
      try #require(try await reopened.loadState(.own).digest == expectedOwn.digest)
      try #require(reconciler.calls.isEmpty)
    }
  }

  @Test("should refuse, by the stored registry, a registry that cannot carry the stored state and leave the database as it was", arguments: refusals.indices)
  func shouldRefuseByStoredRegistry(_ index: Int) async throws {
    let refusal = refusals[index]
    let problems = refusal.registry.incompatibilities(with: Fixture.v1)
    let reason = try await refusedUpgrade(to: refusal.registry)
    #expect(problems.prefix(3).allSatisfy(reason.contains), "\(refusal.name)")
  }

  @Test("should refuse, by the stored registry, a change the stored rows cannot show", arguments: registryOnlyRefusals.indices)
  func shouldRefuseWhatRowsCannotShow(_ index: Int) async throws {
    let refusal = registryOnlyRefusals[index]
    let problems = refusal.registry.incompatibilities(with: Fixture.v1)
    try #require(!problems.isEmpty)
    let reason = try await refusedUpgrade(to: refusal.registry)
    #expect(reason.contains(problems[0]), "\(refusal.name)")
  }

  @Test("should refuse a different registry under the stored version and leave the database as it was")
  func shouldRefuseChangeWithoutVersionBump() async throws {
    let directory = TemporaryDirectory()
    let before = try await StoreImage(try await seededFile(directory))
    let changed = Fixture.registry(version: Fixture.v1.version, noteFields: ["pinned": .register], status: Fixture.statusOrder, marks: ["approved"], tag: false)
    let error = #expect(throws: StoreError.self) { try VaultStore.open(.file(directory.storeURL), registry: changed) }
    guard case .incompatibleRegistry(let reason) = error else { throw StoreTestFailure.unexpectedState }
    #expect(reason.contains("without a version bump"))
    #expect(try await StoreImage(try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1)) == before)
  }

  @Test("should report a missing, undecodable or mismatched description as a corrupt store and leave the database as it was", arguments: plantedDescriptions.indices)
  func shouldRefuseCorruptDescription(_ index: Int) async throws {
    let planted = plantedDescriptions[index]
    let directory = TemporaryDirectory()
    let seeded = try await seededFile(directory)
    try await plantDescription(planted.bytes, in: seeded)
    let before = try await StoreImage(seeded)
    for registry in [Fixture.v1, Fixture.v2] {
      let reconciler = RecordingReconciler()
      let error = #expect(throws: StoreError.self, "\(planted.name)") { try VaultStore.open(.file(directory.storeURL), registry: registry, reconciler: reconciler) }
      #expect(error?.code == "store.corrupt_store", "\(planted.name)")
      #expect(reconciler.events.isEmpty)
    }
    #expect(try await StoreImage(seeded) == before)
    #expect(try await registryVersion(seeded) == Fixture.v1.version)
  }

  @Test("should refuse to plant a null description")
  func shouldRefuseNullDescription() async throws {
    let directory = TemporaryDirectory()
    let seeded = try await seededFile(directory)
    let error = await #expect(throws: StoreError.self) {
      try await seeded.write { transaction in try transaction.database.execute(sql: "UPDATE kernel_state SET registry = NULL") }
    }
    #expect(error?.code == "store.database")
  }

  @Test("should refuse, by the stored rows, rows that contradict a valid stored description and leave the database as it was", arguments: rowPlants)
  fileprivate func shouldRefuseContradictingRows(_ plant: RowPlant) async throws {
    let directory = TemporaryDirectory()
    let seeded = try await seededFile(directory)
    try await seeded.write { transaction in try transaction.database.execute(sql: plant.sql, arguments: plant.arguments) }
    let before = try await rawImage(seeded)
    let reconciler = RecordingReconciler()
    let error = #expect(throws: StoreError.self) { try VaultStore.open(.file(directory.storeURL), registry: Fixture.v2, reconciler: reconciler) }
    guard case .incompatibleRegistry(let reason) = error else { throw StoreTestFailure.unexpectedState }
    #expect(reason == plant.reason)
    #expect(reconciler.events.isEmpty)
    #expect(try await rawImage(seeded) == before)
    #expect(try await registryVersion(seeded) == Fixture.v1.version)
  }

  private func refusedUpgrade(to registry: SchemaRegistry) async throws -> String {
    let directory = TemporaryDirectory()
    let seeded = try await seededFile(directory)
    let before = try await StoreImage(seeded)
    let reconciler = RecordingReconciler()
    let error = #expect(throws: StoreError.self) { try VaultStore.open(.file(directory.storeURL), registry: registry, reconciler: reconciler) }
    guard case .incompatibleRegistry(let reason) = error else { throw StoreTestFailure.unexpectedState }
    #expect(reconciler.events.isEmpty)
    #expect(try await StoreImage(seeded) == before)
    #expect(try await registryVersion(seeded) == Fixture.v1.version)
    return reason
  }

  @Test("should roll the upgrade back when the reconciler throws")
  func shouldRollBackFailingReconciler() async throws {
    let directory = TemporaryDirectory()
    let before = try await StoreImage(try await seededFile(directory))
    let reconciler = RecordingReconciler(failing: true)
    let error = #expect(throws: StoreError.self) { try VaultStore.open(.file(directory.storeURL), registry: Fixture.v2, reconciler: reconciler) }
    #expect(error?.code == "store.reconciler_failed")
    #expect(reconciler.calls.map(\.touched) == [[tag]])
    let reopened = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1)
    #expect(try await StoreImage(reopened) == before)
    #expect(try await registryVersion(reopened) == Fixture.v1.version)
  }

  @Test("should apply a foreign record that the newer registry declares and leave opaque lines alone")
  func shouldLeaveOpaqueLinesAlone() async throws {
    let directory = TemporaryDirectory()
    let opaque = try await seededFile(directory).loadState(.vault).opaqueLines
    let store = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v2)
    let vault = try await store.loadState(.vault)
    #expect(vault.opaqueLines == opaque && opaque.count == 1)
    #expect(vault.foreign.isEmpty)
    guard case .record(let state) = vault.state(of: tag) else { throw StoreTestFailure.unexpectedState }
    #expect(state[field: "label"]?.value == "foreign")
  }

  @Test("should do nothing when opened under the registry it was last opened with")
  func shouldDoNothingForSameRegistry() async throws {
    let directory = TemporaryDirectory()
    let before = try await StoreImage(try await seededFile(directory))
    let reconciler = RecordingReconciler()
    let reopened = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1, reconciler: reconciler)
    #expect(try await StoreImage(reopened) == before)
    #expect(reconciler.calls.isEmpty)
  }
}
