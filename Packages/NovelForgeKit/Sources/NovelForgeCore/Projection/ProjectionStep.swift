import Foundation
import GRDB
import OSLog
import ShadowCore
import ShadowStore

protocol ProjectionStep: Sendable {
  var table: String { get }
  var upstream: [String] { get }
  var layout: String { get }
  var definition: String { get }

  func reconcile(_ changes: inout ProjectionChanges, in context: DerivationContext, faults: StandingFaults) throws(ProjectionError)
  func rebuild(in context: DerivationContext) throws(ProjectionError)
}

func registered<Registered: Derivation>(_ derivation: Registered) -> any ProjectionStep {
  RegisteredDerivation(derivation: derivation)
}

enum ProjectionFaults {
  static let table = "nf_derived_fault"
  static let wholeDerivation = "*"
  static let definition = """
    CREATE TABLE nf_derived_fault (derivation TEXT NOT NULL, key TEXT NOT NULL, version INTEGER NOT NULL, message TEXT NOT NULL, PRIMARY KEY (derivation, key)) STRICT, WITHOUT ROWID
    """
  static let logger = Logger(category: "projection")

  /// How a fault row names the key it is about.
  static func key(_ key: some Hashable & Sendable) -> String { String(reflecting: key) }

  /// The kind of the entity a fault key written for an `EntityRef` names; nil for any other key.
  static func kind(ofKey key: String) -> EntityKind? {
    guard let start = key.range(of: "(kind: "), let end = key.range(of: ", key: ", range: start.upperBound..<key.endIndex) else { return nil }
    return EntityKind(String(key[start.upperBound..<end.lowerBound]))
  }
}

struct StandingFaults {
  let any: Bool
  let wholeDerivations: Set<String>

  init(in database: Database) throws {
    any = try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM \(ProjectionFaults.table))") ?? false
    wholeDerivations =
      any
      ? Set(try String.fetchAll(database, sql: "SELECT derivation FROM \(ProjectionFaults.table) WHERE key = ?", arguments: [ProjectionFaults.wholeDerivation]))
      : []
  }
}

private enum StepFailure: Error {
  case genuine(StoreError)
  case fault(String)
}

private struct RegisteredDerivation<Registered: Derivation>: ProjectionStep {
  let derivation: Registered

  var table: String { Registered.Output.databaseTableName }
  var upstream: [String] { derivation.inputs.compactMap(\.upstream) }
  var definition: String { Registered.definition }
  var layout: String { "\(table)\n\(Registered.version)\n\(Registered.definition)" }

  func reconcile(_ changes: inout ProjectionChanges, in context: DerivationContext, faults: StandingFaults) throws(ProjectionError) {
    guard !faults.wholeDerivations.contains(table) else { return }
    var keys = Set<Registered.Key>()
    for input in derivation.inputs { keys.formUnion(input.keys(changes)) }
    for key in keys { changes.record(Registered.self, try refresh(key, in: context, clearingFault: faults.any, withdrawing: true)) }
  }

  func rebuild(in context: DerivationContext) throws(ProjectionError) {
    let keys: Set<Registered.Key>
    do {
      keys = try reading(context) { () throws(StoreError) in try derivation.allKeys(in: context) }
    } catch {
      switch error {
      case .genuine(let failure): throw .store(failure)
      case .fault(let message): return try record(ProjectionFaults.wholeDerivation, message, in: context.records.database)
      }
    }
    for key in keys { _ = try refresh(key, in: context, clearingFault: false, withdrawing: false) }
  }

  private func refresh(_ key: Registered.Key, in context: DerivationContext, clearingFault: Bool, withdrawing: Bool) throws(ProjectionError) -> Set<Registered.Output> {
    let database = context.records.database
    let changed: Set<Registered.Output>
    do {
      changed = try isolated(in: database) { () throws(StepFailure) in try replace(key, in: context) }
    } catch {
      switch error {
      case .genuine(let failure): throw .store(failure)
      case .fault(let message):
        let withdrawn = withdrawing ? try withdraw(key, in: database) : []
        try record(ProjectionFaults.key(key), message, in: database)
        return withdrawn
      }
    }
    if clearingFault {
      try writing(database) { database in
        try database.execute(sql: "DELETE FROM \(ProjectionFaults.table) WHERE derivation = ? AND key = ?", arguments: [table, ProjectionFaults.key(key)])
      }
    }
    return changed
  }

  private func replace(_ key: Registered.Key, in context: DerivationContext) throws(StepFailure) -> Set<Registered.Output> {
    let request = Registered.request(for: key)
    let stored = Set(try reading(context) { () throws(StoreError) in try context.fetchAll(request) })
    guard stored.allSatisfy({ Registered.key(of: $0) == key }) else { throw .fault("request(for:) selects rows of other keys") }
    let computed = Set(try reading(context) { () throws(StoreError) in try derivation.outputs(for: key, in: context) })
    guard computed.allSatisfy({ Registered.key(of: $0) == key }) else { throw .fault("outputs(for:in:) returned rows of other keys") }
    guard stored != computed else { return [] }
    do {
      try request.deleteAll(context.records.database)
      for output in computed { try output.insert(context.records.database) }
    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      throw .fault("its rows break a constraint: \(error.message ?? "no message")")
    } catch {
      throw .genuine(StoreError(projecting: error))
    }
    return stored.symmetricDifference(computed)
  }

  private func withdraw(_ key: Registered.Key, in database: Database) throws(ProjectionError) -> Set<Registered.Output> {
    try writing(database) { database in
      let owned = Set(try Registered.request(for: key).fetchAll(database).filter { Registered.key(of: $0) == key })
      for output in owned { try output.delete(database) }
      return owned
    }
  }

  private func record(_ key: String, _ message: String, in database: Database) throws(ProjectionError) {
    ProjectionFaults.logger.error(
      "Derivation fault in \(table, privacy: .public) version \(Registered.version, privacy: .public) for \(key, privacy: .private): \(message, privacy: .private)")
    try writing(database) { database in
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES (?, ?, ?, ?)",
        arguments: [table, key, Registered.version, message])
    }
  }

  private func writing<T>(_ database: Database, _ body: (Database) throws -> T) throws(ProjectionError) -> T {
    do {
      return try body(database)
    } catch {
      throw .store(StoreError(projecting: error))
    }
  }

  private func reading<T>(_ context: DerivationContext, _ body: () throws(StoreError) -> T) throws(StepFailure) -> T {
    do {
      return try context.records.database.readOnly { try body() }
    } catch {
      let failure = StoreError(projecting: error)
      if case .database = failure { throw .genuine(failure) }
      throw .fault(failure.description)
    }
  }

  private func isolated<T>(in database: Database, _ body: () throws(StepFailure) -> T) throws(StepFailure) -> T {
    var outcome: Result<T, StepFailure>?
    do {
      try database.inSavepoint {
        do throws(StepFailure) {
          outcome = .success(try body())
          return .commit
        } catch {
          outcome = .failure(error)
          return .rollback
        }
      }
    } catch {
      throw .genuine(StoreError(projecting: error))
    }
    guard let outcome else { throw .genuine(.database("the savepoint ran nothing")) }
    return try outcome.get()
  }
}
