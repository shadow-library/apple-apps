import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let other = SchemaFixture.otherNovel

protocol ProbeTable: Sendable {
  static var name: String { get }
  static var version: Int { get }
  static var wide: Bool { get }
  static var definition: String { get }
}

extension ProbeTable {
  static var version: Int { 1 }
  static var wide: Bool { false }
  static var definition: String { "CREATE TABLE \(name) (novel BLOB PRIMARY KEY) STRICT, WITHOUT ROWID" }
}

enum ProbeTableName: ProbeTable { static let name = "nf_derived_probe" }
enum RaisedProbeTableName: ProbeTable {
  static let name = "nf_derived_probe"
  static let version = 2
}
enum WideTableName: ProbeTable {
  static let name = "nf_derived_wide"
  static let wide = true
}
enum CheckedTableName: ProbeTable {
  static let name = "nf_derived_checked"
  static let definition = "CREATE TABLE nf_derived_checked (novel BLOB PRIMARY KEY CHECK (length(novel) = 0)) STRICT, WITHOUT ROWID"
}
enum StrayTableName: ProbeTable {
  static let name = "nf_derived_stray"
  static let definition = "CREATE TABLE nf_derived_stray (novel BLOB PRIMARY KEY) STRICT; CREATE TABLE nf_derived_extra (novel BLOB) STRICT"
}
enum KeylessTableName: ProbeTable {
  static let name = "nf_derived_keyless"
  static let definition = "CREATE TABLE nf_derived_keyless (novel BLOB) STRICT"
}
enum EmptyTableName: ProbeTable {
  static let name = "nf_derived_empty"
  static let definition = "SELECT 1"
}
enum UnprefixedTableName: ProbeTable { static let name = "derived_probe" }
enum UpperCaseTableName: ProbeTable { static let name = "nf_derived_Probe" }
enum FaultTableName: ProbeTable { static let name = "nf_derived_fault" }

struct ProbeRow<Table: ProbeTable>: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  static var databaseTableName: String { Table.name }

  let novel: UUID
}

enum ProbeBehaviour: Sendable {
  case project
  case projectNothing
  case abortOnNovelNamedFail
  case faultOnNovelNamedFault
  case leak
  case writeWhileReading
  case faultListingKeys
  case faultListingKeysWhilePoisoned
  case abortListingKeys
}

struct ProbeDerivation<Table: ProbeTable>: Derivation {
  static var version: Int { Table.version }
  static var definition: String { Table.definition }

  var behaviour = ProbeBehaviour.project
  var readsFinalChapters = false

  var inputs: [DerivationInput<UUID>] {
    let records = DerivationInput<UUID>.records([.novel]) { ref in novelID(of: ref).map { [$0] } ?? [] }
    guard readsFinalChapters else { return [records] }
    return [records, .outputs(of: FinalChapterDerivation.self) { [$0.novel] }]
  }

  static func key(of output: ProbeRow<Table>) -> UUID { output.novel }

  static func request(for novel: UUID) -> QueryInterfaceRequest<ProbeRow<Table>> {
    Table.wide ? ProbeRow<Table>.all() : ProbeRow<Table>.filter(Column("novel") == novel)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    if behaviour == .faultListingKeys { throw .invalidChange("the probe cannot list its keys") }
    if behaviour == .abortListingKeys { throw .database("the probe lost its connection") }
    let novels = Set(try context.refs(of: .novel).compactMap(novelID(of:)))
    guard behaviour == .faultListingKeysWhilePoisoned else { return novels }
    for id in novels {
      guard case .readable(let entry) = try NovelRecord.read(NovelForgeKey.novel(id), in: context.records), entry.record.name == "poison" else { continue }
      throw .invalidChange("a poisoned novel stops the probe listing its keys")
    }
    return novels
  }

  func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [ProbeRow<Table>] {
    guard case .readable(let entry) = try NovelRecord.read(NovelForgeKey.novel(novel), in: context.records) else { return [] }
    let name = entry.record.name
    switch behaviour {
    case .project: break
    case .projectNothing: return []
    case .abortOnNovelNamedFail: if name == "fail" { throw .database("the probe refuses this novel") }
    case .faultOnNovelNamedFault: if name == "fault" { throw .invalidChange("the probe cannot project this novel") }
    case .leak: return [ProbeRow(novel: novel == other ? novel : other)]
    case .writeWhileReading: try context.read { database in try database.execute(sql: "DELETE FROM \(Table.name)") }
    case .faultListingKeys, .faultListingKeysWhilePoisoned, .abortListingKeys: break
    }
    return [ProbeRow(novel: novel)]
  }
}

private func rows<Table: ProbeTable>(_: Table.Type, in store: VaultStore) async throws -> Set<UUID> {
  Set(try await Projection.fetch(ProbeRow<Table>.all(), in: store).map(\.novel))
}

private func isReconcilerFailure(_ error: any Error) -> Bool {
  guard let error = error as? StoreError, case .reconcilerFailed(let underlying) = error, let projection = underlying as? ProjectionError else { return false }
  guard case .store(.database) = projection else { return false }
  return true
}

private func temporaryStore() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "projection-\(UUID().uuidString)").appending(path: "vault.sqlite")
}

private func withoutDigests(_ reconciler: NovelForgeReconciler, in store: VaultStore) async throws -> DerivedTables {
  var tables = try await Projection.derived(reconciler, in: store)
  tables[IndexedRecord.databaseTableName] = tables[IndexedRecord.databaseTableName]?.map { $0.replacing(#/ digest="[0-9a-f]+"/#, with: "") }
  tables[FinalChapterEntry.databaseTableName] = tables[FinalChapterEntry.databaseTableName]?.map { $0.replacing(#/ canon_clock="[^"]*"/#, with: "") }
  return tables
}

private func expectConsistent(_ reconciler: NovelForgeReconciler, in store: VaultStore) async throws {
  let comparison = try await Projection.compare(reconciler, in: store)
  #expect(comparison.incremental == comparison.rebuilt)
}

@Suite("Projection frame", TestTimeLimit.standard)
struct ProjectionFrameTests {
  @Test func shouldProjectALocalWriteInItsTransactionAndAbortItOnADatabaseError() async throws {
    let reconciler = try Projection.reconciler(NovelForgeDerivations.standard + [ProbeDerivation<ProbeTableName>(behaviour: .abortOnNovelNamedFail)])
    let store = try Projection.store(reconciler)
    try await Projection.createNovel(novel, name: "fine", in: store)
    #expect(try await rows(ProbeTableName.self, in: store) == [novel])

    await #expect { try await Projection.createNovel(other, name: "fail", in: store) } throws: { isReconcilerFailure($0) }
    #expect(try await SchemaFixture.state(NovelForgeKey.novel(other), in: store) == nil)
    #expect(try await store.pendingChanges(limit: .max).count == 1)
    #expect(try await rows(ProbeTableName.self, in: store) == [novel])
    #expect(try await Projection.indexed(NovelForgeKey.novel(other), in: store) == nil)
  }

  @Test func shouldAbortARemoteApplyOnADatabaseError() async throws {
    let writer = try Projection.store(try Projection.reconciler())
    let reconciler = try Projection.reconciler(NovelForgeDerivations.standard + [ProbeDerivation<ProbeTableName>(behaviour: .abortOnNovelNamedFail)])
    let reader = try Projection.store(reconciler)
    try await Projection.createNovel(novel, name: "fail", in: writer)
    let lines = try await Projection.lines(of: writer)

    await #expect { try await reader.applyRemote(lines) } throws: { isReconcilerFailure($0) }
    #expect(try await SchemaFixture.state(NovelForgeKey.novel(novel), in: reader) == nil)
    #expect(try await Projection.derived(reconciler, in: reader).values.allSatisfy(\.isEmpty))

    try await Projection.createNovel(other, name: "fine", in: writer)
    try await Projection.apply(Array(try await Projection.lines(of: writer).dropFirst()), to: reader)
    #expect(try await rows(ProbeTableName.self, in: reader) == [other])
    #expect(try await Projection.cursors(in: reader) == [other: 1])
  }

  @Test func shouldRecordAFaultAndKeepWritingAndSyncingWhenADerivationFails() async throws {
    let reconciler = try Projection.reconciler(NovelForgeDerivations.standard + [ProbeDerivation<ProbeTableName>(behaviour: .faultOnNovelNamedFault)])
    let writer = try Projection.store(reconciler, allowingFaults: true)
    let reader = try Projection.store(reconciler, allowingFaults: true)
    try await Projection.createNovel(novel, name: "fine", in: writer)
    try await Projection.renameNovel(novel, to: "fault", in: writer)
    #expect(try await rows(ProbeTableName.self, in: writer).isEmpty)
    #expect(try await Projection.indexed(NovelForgeKey.novel(novel), in: writer)?.status == .live)
    let faults = try await Projection.faults(reconciler, in: writer)
    #expect(faults.count == 1)
    #expect(faults.first?.contains("store.invalid_change") == true)
    try await expectConsistent(reconciler, in: writer)

    try await Projection.apply(try await Projection.lines(of: writer), to: reader)
    #expect(try await Projection.faults(reconciler, in: reader) == faults)
    #expect(try await Projection.cursors(in: reader) == [novel: 1])

    try await Projection.renameNovel(novel, to: "fine again", in: writer)
    #expect(try await rows(ProbeTableName.self, in: writer) == [novel])
    #expect(try await Projection.faults(reconciler, in: writer).isEmpty)
    try await expectConsistent(reconciler, in: writer)
  }

  @Test func shouldRecordRowsOutsideTheirKeyAsAFault() async throws {
    let reconciler = try Projection.reconciler([ProbeDerivation<ProbeTableName>(behaviour: .leak)])
    let store = try Projection.store(reconciler, allowingFaults: true)
    try await Projection.createNovel(novel, in: store)
    #expect(try await rows(ProbeTableName.self, in: store).isEmpty)
    #expect(try await Projection.faults(reconciler, in: store).first?.contains("rows of other keys") == true)
  }

  @Test func shouldNotLoseAnotherKeysRowsToARequestWiderThanItsKey() async throws {
    let reconciler = try Projection.reconciler([ProbeDerivation<WideTableName>()])
    let store = try Projection.store(reconciler, allowingFaults: true)
    try await Projection.createNovel(novel, in: store)
    try await Projection.createNovel(other, in: store)
    #expect(try await rows(WideTableName.self, in: store) == [novel])
    #expect(try await Projection.faults(reconciler, in: store).first?.contains("selects rows of other keys") == true)
  }

  @Test func shouldRecordADerivationThatWritesWhileReadingAsAFault() async throws {
    let reconciler = try Projection.reconciler([ProbeDerivation<ProbeTableName>(behaviour: .writeWhileReading)])
    let store = try Projection.store(reconciler, allowingFaults: true)
    try await Projection.createNovel(novel, in: store)
    #expect(try await rows(ProbeTableName.self, in: store).isEmpty)
    #expect(try await Projection.faults(reconciler, in: store).first?.contains("tried to write") == true)
  }

  @Test func shouldRecordRowsThatBreakAConstraintAsAFault() async throws {
    let reconciler = try Projection.reconciler([ProbeDerivation<CheckedTableName>()])
    let store = try Projection.store(reconciler, allowingFaults: true)
    try await Projection.createNovel(novel, in: store)
    #expect(try await rows(CheckedTableName.self, in: store).isEmpty)
    #expect(try await Projection.faults(reconciler, in: store).first?.contains("constraint") == true)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldOpenAndKeepWorkingWhenADerivationCannotListItsKeys() async throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let writer = try Projection.store(try Projection.reconciler())
    do {
      let store = try Projection.store(try Projection.reconciler(), at: .file(url))
      try await Projection.createNovel(novel, in: store)
    }
    let reconciler = try Projection.reconciler(NovelForgeDerivations.standard + [ProbeDerivation<ProbeTableName>(behaviour: .faultListingKeys, readsFinalChapters: true)])
    for _ in 0..<2 {
      let store = try Projection.store(reconciler, at: .file(url), allowingFaults: true)
      let faults = try await Projection.faults(reconciler, in: store)
      #expect(faults.count == 1)
      #expect(faults.first?.contains("key=\"*\"") == true)
      #expect(try await rows(ProbeTableName.self, in: store).isEmpty)
    }

    let store = try Projection.store(reconciler, at: .file(url), allowingFaults: true)
    try await Projection.createNovel(other, in: store)
    try await Projection.finalize(novel: other, chapter: 1, in: writer)
    try await Projection.apply(try await Projection.lines(of: writer), to: store)
    #expect(try await rows(ProbeTableName.self, in: store).isEmpty)
    #expect(try await Projection.cursors(in: store) == [novel: 1, other: 2])
    #expect(try await Projection.faults(reconciler, in: store).count == 1)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldRetryADerivationThatCouldNotListItsKeysWhenPreparedAfterOpening() async throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    do {
      let store = try Projection.store(try Projection.reconciler(), at: .file(url))
      try await Projection.createNovel(novel, name: "poison", in: store)
      try await Projection.finalize(novel: novel, chapter: 1, in: store)
    }
    let reconciler = try Projection.reconciler([ProbeDerivation<ProbeTableName>(behaviour: .faultListingKeysWhilePoisoned)] + NovelForgeDerivations.standard)
    do {
      let store = try Projection.store(reconciler, at: .file(url), allowingFaults: true)
      #expect(try await Projection.faults(reconciler, in: store).count == 1)
      try await Projection.renameNovel(novel, to: "fine", in: store)
      #expect(try await rows(ProbeTableName.self, in: store).isEmpty)
      try await reconciler.prepare(store)
      #expect(try await rows(ProbeTableName.self, in: store) == [novel])
      #expect(try await Projection.faults(reconciler, in: store).isEmpty)
      #expect(try await Projection.cursors(in: store) == [novel: 2])
      try await expectConsistent(reconciler, in: store)
    }
    let reopened = try Projection.store(reconciler, at: .file(url))
    try await reconciler.prepare(reopened)
    #expect(try await rows(ProbeTableName.self, in: reopened) == [novel])
  }

  @Test func shouldRefuseToOpenWhenADerivationCannotListItsKeysForADatabaseReason() throws {
    let reconciler = try Projection.reconciler([ProbeDerivation<ProbeTableName>(behaviour: .abortListingKeys)])
    #expect(throws: StoreError.self) { try Projection.store(reconciler) }
  }

  @Test func shouldLeaveNoFaultForAKeyThatIsGoneAfterAResetOrARebuild() async throws {
    let reconciler = try Projection.reconciler([ProbeDerivation<ProbeTableName>(behaviour: .faultOnNovelNamedFault)])
    let store = try Projection.store(reconciler, allowingFaults: true)
    try await Projection.createNovel(novel, name: "fault", in: store)
    let standing = try await Projection.faults(reconciler, in: store)
    #expect(standing.count == 1)
    try await store.write { transaction in
      try transaction.database.execute(
        sql: "INSERT INTO nf_derived_fault (derivation, key, version, message) VALUES ('nf_derived_probe', 'gone', 1, 'stale')")
    }
    #expect(try await Projection.faults(reconciler, in: store).count == 2)

    try await store.write { transaction in try reconciler.rebuild(in: transaction.database) }
    #expect(try await Projection.faults(reconciler, in: store) == standing)
    try await store.write { transaction in try reconciler.reset(in: transaction.database) }
    #expect(try await Projection.faults(reconciler, in: store).isEmpty)
  }

  @Test func shouldFailAStrictTestWriteThatRecordsAFault() async throws {
    let store = try Projection.store(try Projection.reconciler([ProbeDerivation<ProbeTableName>(behaviour: .faultOnNovelNamedFault)]))
    try await Projection.createNovel(novel, name: "fine", in: store)
    await #expect(throws: ProjectionPropertyFailure.self) { try await Projection.createNovel(other, name: "fault", in: store) }
  }

  @Test func shouldRefuseAnInvalidCatalogue() throws {
    #expect(throws: ProjectionError.self) { try Projection.reconciler([ProbeDerivation<UnprefixedTableName>()]) }
    #expect(throws: ProjectionError.self) { try Projection.reconciler([ProbeDerivation<UpperCaseTableName>()]) }
    #expect(throws: ProjectionError.self) { try Projection.reconciler([ProbeDerivation<FaultTableName>()]) }
    #expect(throws: ProjectionError.self) { try Projection.reconciler([ProbeDerivation<ProbeTableName>(), ProbeDerivation<ProbeTableName>()]) }
    #expect(throws: ProjectionError.self) { try Projection.reconciler([ProbeDerivation<ProbeTableName>(readsFinalChapters: true), FinalChapterDerivation()]) }
    #expect(throws: ProjectionError.self) { try Projection.reconciler([StoryCursorDerivation()]) }
    #expect(throws: Never.self) { try Projection.reconciler([FinalChapterDerivation(), ProbeDerivation<ProbeTableName>(readsFinalChapters: true)]) }
  }

  @Test(arguments: [EmptyTableName.name, StrayTableName.name, KeylessTableName.name])
  func shouldRefuseToOpenWhenADefinitionDoesNotCreateExactlyItsKeyedTable(table: String) throws {
    let derivation: any Derivation =
      switch table {
      case EmptyTableName.name: ProbeDerivation<EmptyTableName>()
      case StrayTableName.name: ProbeDerivation<StrayTableName>()
      default: ProbeDerivation<KeylessTableName>()
      }
    let reconciler = try Projection.reconciler([derivation])
    #expect(throws: StoreError.self) { try Projection.store(reconciler) }
  }

  @Test func shouldGiveEachLayoutItsOwnFingerprint() throws {
    let standard = try Projection.reconciler()
    #expect(standard.fingerprint == (try Projection.reconciler()).fingerprint)
    #expect(standard.fingerprint != (try Projection.reconciler(Array(NovelForgeDerivations.standard.dropLast()))).fingerprint)
    #expect(Set(["nf_derived_record", "nf_derived_final_chapter", "nf_derived_story_cursor"]).isSubset(of: standard.tables))
    let raised = try Projection.reconciler([ProbeDerivation<RaisedProbeTableName>()])
    #expect((try Projection.reconciler([ProbeDerivation<ProbeTableName>()])).fingerprint != raised.fingerprint)
    let newerSchema = SchemaRegistry(version: NovelForgeSchema.version + 1, entities: NovelForgeSchema.entities)
    #expect(standard.fingerprint != (try NovelForgeReconciler(registry: newerSchema)).fingerprint)
  }

  @Test func shouldRebuildOnReopenWhenADerivationRaisesItsVersion() async throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    do {
      let store = try Projection.store(try Projection.reconciler([ProbeDerivation<ProbeTableName>(behaviour: .projectNothing)]), at: .file(url))
      try await Projection.createNovel(novel, in: store)
      #expect(try await rows(ProbeTableName.self, in: store).isEmpty)
    }
    do {
      let sameVersion = try Projection.store(try Projection.reconciler([ProbeDerivation<ProbeTableName>()]), at: .file(url))
      #expect(try await rows(ProbeTableName.self, in: sameVersion).isEmpty)
    }
    let raised = try Projection.store(try Projection.reconciler([ProbeDerivation<RaisedProbeTableName>()]), at: .file(url))
    #expect(try await rows(RaisedProbeTableName.self, in: raised) == [novel])
  }

  @Test func shouldRewriteRowsOnlyWhenTheyDiffer() async throws {
    let (writer, reader) = (try Projection.store(try Projection.reconciler()), try Projection.store(try Projection.reconciler()))
    try await Projection.createNovel(novel, in: writer)
    let created = try await Projection.lines(of: writer)
    try await Projection.apply(created, to: reader)
    try await reader.write { transaction in
      try transaction.database.execute(
        sql: """
          CREATE TABLE probe_writes (count INTEGER NOT NULL); INSERT INTO probe_writes VALUES (0);
          CREATE TRIGGER probe_insert AFTER INSERT ON nf_derived_record BEGIN UPDATE probe_writes SET count = count + 1; END;
          CREATE TRIGGER probe_delete AFTER DELETE ON nf_derived_record BEGIN UPDATE probe_writes SET count = count + 1; END;
          """)
    }
    let writes = { @Sendable in try await reader.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT count FROM probe_writes") } }

    try await Projection.apply(created, to: reader)
    #expect(try await writes() == 0)
    try await Projection.renameNovel(novel, to: "Tide", in: writer)
    try await Projection.apply(Array(try await Projection.lines(of: writer).dropFirst(created.count)), to: reader)
    #expect(try await writes() == 2)
  }

  @Test func shouldResetEveryDerivedRowAndRebuildThemFromState() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    try await Projection.createNovel(novel, in: store)
    try await Projection.finalize(novel: novel, chapter: 1, in: store)
    let projected = try await Projection.derived(reconciler, in: store)
    let populated = [IndexedRecord.databaseTableName, FinalChapterEntry.databaseTableName, StoryCursor.databaseTableName]
    #expect(populated.allSatisfy { !(projected[$0] ?? []).isEmpty })

    try await store.write { transaction in try reconciler.reset(in: transaction.database) }
    #expect(try await Projection.derived(reconciler, in: store).values.allSatisfy(\.isEmpty))
    try await store.write { transaction in try reconciler.rebuild(in: transaction.database) }
    #expect(try await Projection.derived(reconciler, in: store) == projected)
  }

  @Test func shouldMatchARebuildAfterARemintThatRebuildsState() async throws {
    let reconciler = try Projection.reconciler()
    let writer = try Projection.store(reconciler)
    let store = try Projection.store(reconciler)
    try await Projection.createNovel(novel, in: writer)
    for chapter in [1, 2] { try await Projection.finalize(novel: novel, chapter: chapter, in: writer) }
    let remote = try await Projection.lines(of: writer)
    try await Projection.apply(remote, to: store)
    try await Projection.finalize(novel: novel, chapter: 3, in: store)
    let before = try await withoutDigests(reconciler, in: store)
    #expect(try await Projection.cursors(in: store) == [novel: 4])

    try await store.remint(to: ReplicaID(UUID.v7()), mode: .rebuild)
    #expect(try await Projection.finals(in: store).map(\.chapter) == [3])
    #expect(try await Projection.cursors(in: store) == [novel: 1])
    try await expectConsistent(reconciler, in: store)

    try await Projection.apply(remote, to: store)
    #expect(try await withoutDigests(reconciler, in: store) == before)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldBackfillNewTablesAndDropRetiredOnesWhenTheCatalogueChanges() async throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let indexOnly = try Projection.reconciler(ProjectionDerivations.all)
    let standard = try Projection.reconciler()
    do {
      let store = try Projection.store(indexOnly, at: .file(url))
      try await Projection.createNovel(novel, in: store)
      try await Projection.finalize(novel: novel, chapter: 1, in: store)
    }

    let upgraded = try Projection.store(standard, at: .file(url))
    #expect(try await Projection.cursors(in: upgraded) == [novel: 2])
    #expect(try await Projection.finals(in: upgraded).map(\.chapter) == [1])
    try await expectConsistent(standard, in: upgraded)

    let downgraded = try Projection.store(indexOnly, at: .file(url))
    let tables = try await downgraded.read { transaction in
      try ["nf_derived_record", "nf_derived_final_chapter", "nf_derived_story_cursor"].map { try transaction.database.tableExists($0) }
    }
    #expect(tables == [true, false, false])
  }

  @Test func shouldLayOutTablesOnTheFirstReconcileWhenOpenedWithoutTheMigration() async throws {
    let reconciler = try Projection.reconciler()
    let store = try VaultStore.open(.inMemory, registry: Projection.registry, reconciler: reconciler)
    try await Projection.createNovel(novel, in: store)
    #expect(try await Projection.cursors(in: store) == [novel: 1])
    #expect(try await Projection.indexed(NovelForgeKey.novel(novel), in: store)?.status == .live)
  }
}
