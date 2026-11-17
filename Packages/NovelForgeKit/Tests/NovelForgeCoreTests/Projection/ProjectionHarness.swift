import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization

@testable import NovelForgeCore

typealias DerivedTables = [String: [String]]

struct IndexEntry: Equatable {
  let ref: EntityRef
  let novel: UUID?
  let status: IndexedStatus
}

struct ProjectionComparison: Equatable {
  let incremental: DerivedTables
  let rebuilt: DerivedTables
}

enum Projection {
  static let registry = SchemaFixture.registry

  static func reconciler(_ derivations: [any Derivation] = NovelForgeDerivations.standard) throws -> NovelForgeReconciler {
    try NovelForgeReconciler(registry: registry, derivations: derivations)
  }

  private static let faultTolerant = Mutex<[VaultStore]>([])

  /// Every write and apply through these helpers fails on a recorded fault unless the store was opened with `allowingFaults`.
  static func store(
    _ reconciler: NovelForgeReconciler, at location: StoreLocation = .inMemory, clock: SchemaTestClock = SchemaTestClock(), allowingFaults: Bool = false
  ) throws -> VaultStore {
    let store = try VaultStore.open(location, registry: registry, migrations: reconciler.migrations, wallClock: clock.function, reconciler: reconciler)
    if allowingFaults { faultTolerant.withLock { $0.append(store) } }
    return store
  }

  static func write<T: Sendable>(_ store: VaultStore, _ body: @Sendable (inout WriteTransaction) throws -> T) async throws -> T {
    let result = try await store.write(body)
    try await expectNoFaults(in: store)
    return result
  }

  @discardableResult
  static func apply(_ lines: [Data], to store: VaultStore) async throws -> RemoteApplyResult {
    let result = try await store.applyRemote(lines)
    try await expectNoFaults(in: store)
    return result
  }

  static func expectNoFaults(in store: VaultStore) async throws {
    guard !faultTolerant.withLock({ $0.contains { $0 === store } }) else { return }
    let faults = try await store.read { transaction in
      guard try transaction.database.tableExists(ProjectionFaults.table) else { return [String]() }
      return try String.fetchAll(transaction.database, sql: "SELECT derivation || ' ' || key || ': ' || message FROM \(ProjectionFaults.table)")
    }
    guard faults.isEmpty else { throw ProjectionPropertyFailure.faults(faults) }
  }

  static func tables(_ reconciler: NovelForgeReconciler, in database: Database) throws -> DerivedTables {
    var tables = DerivedTables()
    for table in reconciler.tables + [reconciler.faultTable] {
      tables[table] = try Row.fetchAll(database, sql: "SELECT * FROM \(table)").map(line).sorted()
    }
    return tables
  }

  private static func line(_ row: Row) -> String {
    zip(row.columnNames, row.databaseValues).map { name, value in
      switch value.storage {
      case .null: "\(name)=null"
      case .int64(let number): "\(name)=\(number)"
      case .double(let number): "\(name)=\(number)"
      case .string(let text): "\(name)=\"\(text)\""
      case .blob(let bytes): "\(name)=x\(bytes.map { String(format: "%02x", $0) }.joined())"
      }
    }.joined(separator: " ")
  }

  static func derived(_ reconciler: NovelForgeReconciler, in store: VaultStore) async throws -> DerivedTables {
    try await store.read { transaction in try tables(reconciler, in: transaction.database) }
  }

  static func compare(_ reconciler: NovelForgeReconciler, in store: VaultStore) async throws -> ProjectionComparison {
    try await store.write { transaction in
      let database = transaction.database
      let incremental = try tables(reconciler, in: database)
      var rebuilt = DerivedTables()
      try database.inSavepoint {
        try reconciler.rebuild(in: database)
        rebuilt = try tables(reconciler, in: database)
        return .rollback
      }
      return ProjectionComparison(incremental: incremental, rebuilt: rebuilt)
    }
  }

  static func faults(_ reconciler: NovelForgeReconciler, in store: VaultStore) async throws -> [String] {
    try await derived(reconciler, in: store)[reconciler.faultTable] ?? []
  }

  static func fetch<Output: FetchableRecord & Sendable>(_ request: QueryInterfaceRequest<Output>, in store: VaultStore) async throws -> [Output] {
    try await store.read { transaction in try request.fetchAll(transaction.database) }
  }

  static func finals(in store: VaultStore) async throws -> [FinalChapterEntry] {
    try await fetch(FinalChapterEntry.order(Column("novel"), Column("chapter")), in: store)
  }

  static func cursors(in store: VaultStore) async throws -> [UUID: Int] {
    Dictionary(uniqueKeysWithValues: try await fetch(StoryCursor.all(), in: store).map { ($0.novel, $0.chapter) })
  }

  static func indexed(_ ref: EntityRef, in store: VaultStore) async throws -> IndexedRecord? {
    try await fetch(RecordIndexDerivation.request(for: ref), in: store).first
  }

  static func entry(_ ref: EntityRef, in store: VaultStore) async throws -> IndexEntry? {
    try await indexed(ref, in: store).map { IndexEntry(ref: $0.ref, novel: $0.novel, status: $0.status) }
  }

  static func canon(_ body: String = "The tide turns.") -> Canon {
    Canon(draftRevision: "v:draft", planRevision: "v:plan", body: body)
  }

  static func finalize(novel: UUID, chapter: Int, body: String = "The tide turns.", in store: VaultStore) async throws {
    let record = try FinalChapterRecord(novel: novel, chapter: chapter, canon: canon(body))
    _ = try await write(store) { transaction in try record.finalize(in: &transaction) }
  }

  static func createNovel(_ id: UUID, name: String = "Ember", in store: VaultStore) async throws {
    _ = try await write(store) { transaction in try NovelRecord(id: id, name: name).create(in: &transaction) }
  }

  static func renameNovel(_ id: UUID, to name: String, in store: VaultStore) async throws {
    var edit = NovelEdit()
    edit.name = .set(name)
    let changes = edit
    _ = try await write(store) { transaction in try NovelRecord.edit(id: id, changes, in: &transaction) }
  }

  static func set(_ ref: EntityRef, _ fields: [String: JSONValue], in store: VaultStore) async throws {
    _ = try await write(store) { transaction in try transaction.set(ref, fields) }
  }

  static func purge(_ ref: EntityRef, in store: VaultStore) async throws {
    _ = try await write(store) { transaction in try transaction.purge(ref) }
  }

  static func lines(of store: VaultStore) async throws -> [Data] {
    try await store.pendingChanges(limit: Int.max).map(\.line)
  }
}

typealias ProjectionWrite = @Sendable (inout WriteTransaction) throws -> Void

struct ProjectionUniverse: Sendable {
  let novels: [UUID]
  let chapters: ClosedRange<Int>
  let volumes: [String]

  init(_ generator: inout SeededGenerator) {
    novels = [generator.uuid(), generator.uuid()]
    chapters = 1...4
    volumes = ["one", "two"]
  }

  func novel(_ generator: inout SeededGenerator) -> UUID { generator.pick(from: novels) }
  func chapter(_ generator: inout SeededGenerator) -> Int { generator.int(in: chapters) }
  func volume(_ generator: inout SeededGenerator) -> VolumeRecord { VolumeRecord(novel: novel(&generator), volume: generator.pick(from: volumes), ordinal: 1) }
  func text(_ generator: inout SeededGenerator) -> String { generator.pick(from: ["Ember", "Tide", "Salt"]) }
}

/// A random domain write; later derivations add operations for the kinds they read, including content edits.
struct ProjectionOperation: Sendable {
  let name: String
  let weight: Int
  let make: @Sendable (inout SeededGenerator, ProjectionUniverse) -> ProjectionWrite
}

enum ProjectionOperations {
  static let novels: [ProjectionOperation] = [
    ProjectionOperation(name: "create novel", weight: 2) { generator, universe in
      let record = NovelRecord(id: universe.novel(&generator), name: universe.text(&generator))
      return { transaction in _ = try record.create(in: &transaction) }
    },
    ProjectionOperation(name: "rename novel", weight: 1) { generator, universe in
      let novel = universe.novel(&generator)
      var edit = NovelEdit()
      edit.name = .set(universe.text(&generator))
      let changes = edit
      return { transaction in _ = try NovelRecord.edit(id: novel, changes, in: &transaction) }
    },
    ProjectionOperation(name: "purge novel", weight: 1) { generator, universe in
      let ref = NovelForgeKey.novel(universe.novel(&generator))
      let purges = generator.chance(0.3)
      return { transaction in if purges { _ = try transaction.purge(ref) } }
    },
  ]

  static let volumes: [ProjectionOperation] = [
    ProjectionOperation(name: "create volume", weight: 1) { generator, universe in
      let volume = universe.volume(&generator)
      return { transaction in _ = try volume.create(in: &transaction) }
    },
    ProjectionOperation(name: "edit volume ordinal", weight: 2) { generator, universe in
      let volume = universe.volume(&generator)
      var edit = VolumeEdit()
      edit.ordinal = .set(generator.int(in: 1...9))
      let changes = edit
      return { transaction in _ = try VolumeRecord.edit(volume.ref, changes.fields, in: &transaction) }
    },
    ProjectionOperation(name: "remove volume", weight: 1) { generator, universe in
      let ref = universe.volume(&generator).ref
      return { transaction in _ = try VolumeRecord.remove(ref, in: &transaction) }
    },
    ProjectionOperation(name: "restore volume", weight: 1) { generator, universe in
      let volume = universe.volume(&generator)
      return { transaction in _ = try volume.restore(in: &transaction) }
    },
  ]

  static let notebook: [ProjectionOperation] = [
    ProjectionOperation(name: "append Notebook entry", weight: 1) { generator, universe in
      let text = universe.text(&generator)
      let entry = NotebookEntryRecord(id: generator.uuid(), novel: universe.novel(&generator), entryKind: .known(.decision), topic: text, statement: text)
      return { transaction in _ = try entry.append(in: &transaction) }
    }
  ]

  static let chapters: [ProjectionOperation] = [
    ProjectionOperation(name: "finalize chapter", weight: 3) { generator, universe in
      let (novel, chapter, text) = (universe.novel(&generator), universe.chapter(&generator), universe.text(&generator))
      return { transaction in _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: Projection.canon(text)).finalize(in: &transaction) }
    },
    ProjectionOperation(name: "amend final chapter", weight: 1) { generator, universe in
      let (novel, chapter, text) = (universe.novel(&generator), universe.chapter(&generator), universe.text(&generator))
      return { transaction in
        let ref = try FinalChapterRecord.ref(novel: novel, chapter: chapter)
        guard case .readable = try FinalChapterRecord.read(ref, in: transaction) else { return }
        _ = try FinalChapterRecord.amend(ref, FinalChapterText(title: text, body: text), in: &transaction)
      }
    },
    ProjectionOperation(name: "purge final chapter", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in _ = try transaction.purge(try FinalChapterRecord.ref(novel: novel, chapter: chapter)) }
    },
    ProjectionOperation(name: "create draft", weight: 1) { generator, universe in
      let (novel, chapter, content) = (universe.novel(&generator), universe.chapter(&generator), Gen.draftContent(&generator))
      return { transaction in _ = try DraftRecord(novel: novel, chapter: chapter, content: content).create(in: &transaction) }
    },
    ProjectionOperation(name: "revise draft", weight: 1) { generator, universe in
      let (novel, chapter, content) = (universe.novel(&generator), universe.chapter(&generator), Gen.draftContent(&generator))
      return { transaction in _ = try DraftRecord.revise(try NovelForgeKey.draft(novel: novel, chapter: chapter), content, in: &transaction) }
    },
    ProjectionOperation(name: "revise a draft that has no key", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in _ = try transaction.revise(try NovelForgeKey.draft(novel: novel, chapter: chapter), body: .object(["body": .int(1)])) }
    },
  ]

  static let standard = novels + volumes + notebook + chapters

  /// Chat sessions, messages, summaries, proposals and their changes (Reconcile/Chat), raw shapes and purges included.
  static let chat = ChatOperations.all

  static func pick(from operations: [ProjectionOperation], _ generator: inout SeededGenerator) -> ProjectionOperation? {
    var remaining = generator.int(in: 0...max(operations.map(\.weight).reduce(0, +) - 1, 0))
    for operation in operations {
      if remaining < operation.weight { return operation }
      remaining -= operation.weight
    }
    return operations.last
  }
}

/// Three replicas, random writes and deliveries in any order: after every step the replica it touched holds derived tables equal to a rebuild and no
/// fault; after settling every replica does and holds the same tables, and `settled` checks them against an oracle.
struct ProjectionProperty: Sendable {
  /// Unset (local default), a `ProjectionProperty` and the record helpers run `defaultShare` of their iterations; `NOVELFORGE_PROPERTY_SCALE=n` runs `n` times the full count: 1 is full strength (CI), 4 the deep mutation run.
  static let scale = ProcessInfo.processInfo.environment["NOVELFORGE_PROPERTY_SCALE"].flatMap(Int.init).map { max($0, 1) } ?? 1
  static let isFullStrength = ProcessInfo.processInfo.environment["NOVELFORGE_PROPERTY_SCALE"].flatMap(Int.init) != nil
  static let defaultShare = 0.5

  static func iterations(full: Int) -> Int {
    isFullStrength ? full * scale : max(1, Int((Double(full) * defaultShare).rounded(.up)))
  }

  static func gatedIterations(_ count: Int) -> Int { count * scale }

  var derivations: [any Derivation] = NovelForgeDerivations.standard
  var operations = ProjectionOperations.standard
  var iterations = 10
  var steps = 28
  /// Keeps every iteration at the default scale, for a property whose coverage gate or kills need them.
  var gated = false
  /// Off for a property that only explores states for its oracle: the rebuild comparison then runs once, after settling.
  var checksEveryStep = true
  var settled: @Sendable (NovelForgeReconciler, VaultStore, ProjectionUniverse) async throws -> Void = { _, _, _ in }

  func check(order: CausalReplicaOrder, seed: UInt64) async throws {
    let reconciler = try Projection.reconciler(derivations)
    try await forAllConcurrently(iterations: gated ? Self.gatedIterations(iterations) : Self.iterations(full: iterations), seed: seed) { generator in
      let replicas = try await CausalReplicas(
        CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, order: order, reconciler: { _ in reconciler }, seed: generator.next()))
      let universe = ProjectionUniverse(&generator)
      for _ in 0..<steps {
        var touched: Int?
        if generator.chance(0.5), let operation = ProjectionOperations.pick(from: operations, &generator) {
          let index = generator.int(in: 0...2)
          await replicas.advanceClock(of: index, by: .milliseconds(generator.int(in: 0...50)))
          try await write(operation.make(&generator, universe), on: index, in: replicas)
          touched = index
        } else {
          let delivered = await replicas.deliveries().count
          if try await replicas.step(using: &generator), await replicas.deliveries().count > delivered { touched = await replicas.deliveries().last?.reader }
        }
        if checksEveryStep, let touched { try await expectConsistent(reconciler, in: await replicas.store(touched)) }
      }
      try await replicas.settle()
      let first = try await Projection.derived(reconciler, in: await replicas.store(0))
      for index in 0..<3 {
        let store = await replicas.store(index)
        try await expectConsistent(reconciler, in: store)
        guard try await Projection.derived(reconciler, in: store) == first else { throw ProjectionPropertyFailure.diverged(replica: index) }
        try await settled(reconciler, store, universe)
      }
    }
  }

  private func write(_ body: @escaping ProjectionWrite, on index: Int, in replicas: CausalReplicas) async throws {
    do {
      try await replicas.write(index, body)
    } catch let error as StoreError {
      guard case .reconcilerFailed = error else { return }
      throw error
    }
  }

  private func expectConsistent(_ reconciler: NovelForgeReconciler, in store: VaultStore) async throws {
    let comparison = try await Projection.compare(reconciler, in: store)
    guard comparison.incremental == comparison.rebuilt else { throw ProjectionPropertyFailure.notARebuild(comparison) }
    let faults = comparison.incremental[reconciler.faultTable] ?? []
    guard faults.isEmpty else { throw ProjectionPropertyFailure.faults(faults) }
  }
}

enum ProjectionPropertyFailure: Error {
  case notARebuild(ProjectionComparison)
  case faults([String])
  case diverged(replica: Int)
  case oracle(String)
}

struct HighestVolume: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "nf_derived_test_highest_volume"

  let novel: UUID
  let ordinal: Int
}

/// The pattern for a per-novel aggregate over a hash-keyed kind: subscribe to the record index, filter by kind, read the novel's refs from it.
struct HighestVolumeDerivation: Derivation {
  static let version = 1
  static let definition = "CREATE TABLE nf_derived_test_highest_volume (novel BLOB PRIMARY KEY, ordinal INTEGER NOT NULL) STRICT, WITHOUT ROWID"

  var inputs: [DerivationInput<UUID>] {
    [.outputs(of: RecordIndexDerivation.self) { row in row.kind == .volume ? row.novel.map { [$0] } ?? [] : [] }]
  }

  static func key(of output: HighestVolume) -> UUID { output.novel }

  static func request(for novel: UUID) -> QueryInterfaceRequest<HighestVolume> {
    HighestVolume.filter(Column("novel") == novel)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(IndexedRecord.filter(Column("kind") == NovelForgeKind.volume)).compactMap(\.novel))
  }

  func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [HighestVolume] {
    var ordinals = [Int]()
    for row in try context.fetchAll(IndexedRecord.filter(Column("novel") == novel && Column("kind") == NovelForgeKind.volume)) {
      guard case .readable(let entry) = try VolumeRecord.read(row.ref, in: context.records), !entry.isRemoved else { continue }
      ordinals.append(entry.record.ordinal)
    }
    return ordinals.max().map { [HighestVolume(novel: novel, ordinal: $0)] } ?? []
  }
}

struct VersionCount: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "nf_derived_test_version_count"

  let novel: UUID
  let versions: Int
}

struct VersionCountDerivation: Derivation {
  static let version = 1
  static let definition = "CREATE TABLE nf_derived_test_version_count (novel BLOB PRIMARY KEY, versions INTEGER NOT NULL) STRICT, WITHOUT ROWID"

  var inputs: [DerivationInput<UUID>] {
    [.outputs(of: RecordIndexDerivation.self) { row in row.kind == .draft ? row.novel.map { [$0] } ?? [] : [] }]
  }

  static func key(of output: VersionCount) -> UUID { output.novel }

  static func request(for novel: UUID) -> QueryInterfaceRequest<VersionCount> {
    VersionCount.filter(Column("novel") == novel)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(IndexedRecord.filter(Column("kind") == NovelForgeKind.draft)).compactMap(\.novel))
  }

  func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [VersionCount] {
    var versions = 0
    for row in try context.fetchAll(IndexedRecord.filter(Column("novel") == novel && Column("kind") == NovelForgeKind.draft)) {
      guard case .revisioned(let state)? = try context.records.state(of: row.ref, scope: .vault) else { continue }
      versions += state.revisions.count
    }
    return versions == 0 ? [] : [VersionCount(novel: novel, versions: versions)]
  }
}
