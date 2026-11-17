import Foundation
import GRDB
import ShadowStore

/// `ReadFaults` for a read about one session or proposal: chat derivations are keyed by its ref, so a fault on that key is an entry fault elsewhere but
/// blocks this read.
struct ChatReadFaults {
  let report: ReadFaults
  private let own: [ReadFault]

  init(novel: UUID?, subject: EntityRef?, reading tables: [String], in transaction: ReadTransaction) throws(StoreError) {
    let rows = try FaultRows(in: transaction)
    report = ReadFaults(novel: novel, reading: tables, from: rows)
    guard let subject else {
      own = []
      return
    }
    let key = ProjectionFaults.key(subject)
    own = rows.rows.compactMap { row -> ReadFault? in
      let derivation: String = row["derivation"]
      let faulted: String = row["key"]
      guard tables.contains(derivation), faulted == key else { return nil }
      return ReadFault(derivation: derivation, scope: .entry, message: row["message"])
    }
  }

  var relevant: [ReadFault] { report.relevant }

  func section<Value>(_ tables: [String], _ body: () throws(StoreError) -> Value) throws(StoreError) -> Derived<Value> {
    let blocked = report.blocking(tables) + own
    guard blocked.isEmpty else { return .unavailable(blocked) }
    return .available(try body())
  }
}
