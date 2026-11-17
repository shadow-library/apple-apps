import Foundation
import GRDB
import ShadowStore

public struct ReadFault: Sendable, Hashable {
  public enum Scope: Sendable, Hashable {
    case wholeDerivation
    case novel
    case entry
  }

  public let derivation: String
  public let scope: Scope
  public let message: String

  public var blocks: Bool { scope != .entry }
}

public enum Derived<Value: Sendable & Equatable>: Sendable, Equatable {
  case available(Value)
  case unavailable([ReadFault])

  public var value: Value? {
    guard case .available(let value) = self else { return nil }
    return value
  }

  public var isUnavailable: Bool { value == nil }

  func map<Other: Sendable & Equatable, Failure: Error>(_ transform: (Value) throws(Failure) -> Other) throws(Failure) -> Derived<Other> {
    switch self {
    case .available(let value): .available(try transform(value))
    case .unavailable(let faults): .unavailable(faults)
    }
  }
}

enum DerivedDependencies {
  static let upstream: [String: Set<String>] = {
    var direct = [String: Set<String>]()
    for derivation in NovelForgeDerivations.standard {
      let step = registered(derivation)
      direct[step.table] = Set(step.upstream)
    }
    return direct
  }()

  static func closure(of tables: [String]) -> Set<String> {
    var found = Set<String>()
    var pending = tables
    while let table = pending.popLast() {
      guard found.insert(table).inserted else { continue }
      pending.append(contentsOf: upstream[table] ?? [])
    }
    return found
  }
}

struct FaultRows {
  let rows: [Row]

  init(in transaction: ReadTransaction) throws(StoreError) {
    rows = try transaction.query { database in try Row.fetchAll(database, sql: "SELECT derivation, key, message FROM \(ProjectionFaults.table)") }
  }
}

struct ReadFaults {
  let relevant: [ReadFault]

  init(novel: UUID?, reading tables: [String], in transaction: ReadTransaction) throws(StoreError) {
    self.init(novel: novel, reading: tables, from: try FaultRows(in: transaction))
  }

  init(novel: UUID?, reading tables: [String], from stored: FaultRows) {
    let closure = DerivedDependencies.closure(of: tables)
    let rows = stored.rows
    let own = novel.map { String(reflecting: $0) }
    relevant = rows.compactMap { row -> ReadFault? in
      let derivation: String = row["derivation"]
      let key: String = row["key"]
      guard closure.contains(derivation) else { return nil }
      let scope: ReadFault.Scope
      if key == ProjectionFaults.wholeDerivation {
        scope = .wholeDerivation
      } else if key == own {
        scope = .novel
      } else if UUID(uuidString: key) != nil {
        return nil
      } else {
        scope = .entry
      }
      return ReadFault(derivation: derivation, scope: scope, message: row["message"])
    }.sorted { ($0.derivation, $0.message) < ($1.derivation, $1.message) }
  }

  func blocking(_ tables: [String]) -> [ReadFault] {
    let closure = DerivedDependencies.closure(of: tables)
    return relevant.filter { $0.blocks && closure.contains($0.derivation) }
  }

  func section<Value>(_ tables: [String], _ body: () throws(StoreError) -> Value) throws(StoreError) -> Derived<Value> {
    let blocked = blocking(tables)
    guard blocked.isEmpty else { return .unavailable(blocked) }
    return .available(try body())
  }
}
