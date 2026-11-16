import Foundation
import GRDB
import ShadowStore

public struct NovelForgeReconciler: StoreReconciler {
  static let tablePrefix = "nf_derived_"
  static let layoutTable = "nf_derived_layout"
  static let migrationPrefix = "novelforge.derived."

  public let registry: SchemaRegistry
  public let fingerprint: String
  private let steps: [any ProjectionStep]

  public init(registry: SchemaRegistry, derivations: [any Derivation] = NovelForgeDerivations.standard) throws(ProjectionError) {
    var steps = [any ProjectionStep]()
    var seen = Set<String>()
    for derivation in derivations {
      let step = registered(derivation)
      guard Self.isDerivedTableName(step.table) else { throw .invalidTableName(step.table) }
      for upstream in step.upstream where !seen.contains(upstream) { throw .upstreamNotBefore(table: step.table, upstream: upstream) }
      guard seen.insert(step.table).inserted else { throw .duplicateTable(step.table) }
      steps.append(step)
    }
    self.registry = registry
    self.steps = steps
    let layouts = ["\(registry.version)\n\(registry.canonicalDescription().base64EncodedString())", ProjectionFaults.definition] + steps.map(\.layout)
    fingerprint = sha256Hex(layouts.map { "\($0.utf8.count):\($0)" }.joined())
  }

  public var tables: [String] { steps.map(\.table) }

  public var faultTable: String { ProjectionFaults.table }

  /// Pass these to `VaultStore.open` so derived tables are laid out and rebuilt at open; otherwise that happens at the first write or sync.
  public var migrations: [StoreMigration] {
    let reconciler = self
    let identifier = Self.migrationPrefix + fingerprint
    return [
      StoreMigration(identifier: identifier) { database in
        try reconciler.prepare(in: database)
        // GRDB runs an identifier once; forgetting the other layouts lets one that comes back (an older build reopening the file) lay out again.
        try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier LIKE ? AND identifier <> ?", arguments: [Self.migrationPrefix + "%", identifier])
      }
    ]
  }

  public func reconcile(_ touched: [EntityRef], origin: ChangeOrigin, in database: Database) throws {
    if try layOut(in: database) { return try project(in: database) }
    var changes = ProjectionChanges(touched: touched)
    let context = context(in: database)
    let faults = try execute(in: database) { database in try StandingFaults(in: database) }
    for step in steps { try step.reconcile(&changes, in: context, faults: faults) }
  }

  public func reset(in database: Database) throws {
    try layOut(in: database)
    try clear(in: database)
  }

  /// Lays out a changed layout, or retries every derivation from the first one whose keys could not be listed. A migration runs once per layout, so
  /// call `prepare(_:)` after each open to retry.
  public func prepare(in database: Database) throws(ProjectionError) {
    if try layOut(in: database) { return try project(in: database) }
    let faults = try execute(in: database) { database in try StandingFaults(in: database) }
    guard let first = steps.firstIndex(where: { faults.wholeDerivations.contains($0.table) }) else { return }
    let retried = steps[first...]
    try execute(in: database) { database in
      for step in retried {
        try database.execute(sql: "DELETE FROM \(step.table)")
        try database.execute(sql: "DELETE FROM \(ProjectionFaults.table) WHERE derivation = ?", arguments: [step.table])
      }
    }
    let context = context(in: database)
    for step in retried { try step.rebuild(in: context) }
  }

  public func prepare(_ store: VaultStore) async throws(StoreError) {
    let reconciler = self
    try await store.write { transaction in try reconciler.prepare(in: transaction.database) }
  }

  public func rebuild(in database: Database) throws(ProjectionError) {
    try layOut(in: database)
    try clear(in: database)
    try project(in: database)
  }

  private func project(in database: Database) throws(ProjectionError) {
    let context = context(in: database)
    for step in steps { try step.rebuild(in: context) }
  }

  private func clear(in database: Database) throws(ProjectionError) {
    try execute(in: database) { database in
      for table in tables + [ProjectionFaults.table] { try database.execute(sql: "DELETE FROM \(table)") }
    }
  }

  @discardableResult
  private func layOut(in database: Database) throws(ProjectionError) -> Bool {
    try execute(in: database) { database in
      try database.execute(
        sql: "CREATE TABLE IF NOT EXISTS \(Self.layoutTable) (slot INTEGER PRIMARY KEY CHECK (slot = 1), fingerprint TEXT NOT NULL, tables TEXT NOT NULL) STRICT")
      let stored = try String.fetchOne(database, sql: "SELECT fingerprint FROM \(Self.layoutTable)")
      guard stored != fingerprint else { return false }
      let previous = try String.fetchOne(database, sql: "SELECT tables FROM \(Self.layoutTable)") ?? ""
      let dropped = Set(previous.split(separator: " ").map(String.init).filter(Self.isDerivedTableName) + tables + [ProjectionFaults.table])
      for table in dropped.sorted() { try database.execute(sql: "DROP TABLE IF EXISTS \(table)") }
      try database.execute(sql: ProjectionFaults.definition)
      for step in steps { try Self.define(step, in: database) }
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(Self.layoutTable) (slot, fingerprint, tables) VALUES (1, ?, ?)", arguments: [fingerprint, tables.joined(separator: " ")])
      return true
    }
  }

  private static func define(_ step: any ProjectionStep, in database: Database) throws {
    let objects = "SELECT type || ' ' || name FROM sqlite_master"
    let before = Set(try String.fetchAll(database, sql: objects))
    try database.execute(sql: step.definition)
    let after = Set(try String.fetchAll(database, sql: objects))
    guard try database.tableExists(step.table) else { throw ProjectionError.missingTable(step.table) }
    let foreign = Set(try String.fetchAll(database, sql: objects + " WHERE NOT (tbl_name = ? AND type IN ('table', 'index'))", arguments: [step.table]))
    if let stray = (after.subtracting(before).intersection(foreign).union(before.subtracting(after))).sorted().first {
      throw ProjectionError.definitionOutsideTable(table: step.table, object: stray)
    }
    guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM pragma_table_info(?) WHERE pk > 0", arguments: [step.table]) ?? 0 > 0 else {
      throw ProjectionError.missingPrimaryKey(step.table)
    }
  }

  private func context(in database: Database) -> DerivationContext {
    DerivationContext(records: ReadTransaction(database: database, registry: registry))
  }

  private func execute<T>(in database: Database, _ body: (Database) throws -> T) throws(ProjectionError) -> T {
    do {
      return try body(database)
    } catch let error as ProjectionError {
      throw error
    } catch {
      throw .store(StoreError(projecting: error))
    }
  }

  private static func isDerivedTableName(_ table: String) -> Bool {
    guard table.hasPrefix(tablePrefix), table != layoutTable, table != ProjectionFaults.table, table.utf8.count > tablePrefix.utf8.count else { return false }
    return table.utf8.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: "_") }
  }
}
