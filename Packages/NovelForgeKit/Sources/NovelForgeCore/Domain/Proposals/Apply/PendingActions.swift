import Foundation
import GRDB
import ShadowStore

/// An applied card whose selected actions have not all settled on this device.
struct PendingActionRow: Sendable, Equatable {
  let proposal: UUID
  let novel: UUID
  /// The action indexes still to settle, ascending; nil when the stored list cannot be read.
  let actions: [Int]?
  let attempts: Int
  /// Why the last sweep left actions pending.
  let fault: String?
}

/// What a launch sweep did with one row of `PendingActions`.
enum PendingActionResume: Sendable, Equatable {
  /// No action of the card is pending any more, and its row was removed; the results are those `resumeProposalActions` reports.
  case resumed(proposal: UUID, [ProposalActionResult])
  /// The card is not found here (RFN_001), so its row was removed.
  case forgotten(proposal: UUID, code: String)
  /// Actions are still pending after this sweep; the row is kept with the code.
  case faulted(proposal: UUID, code: String)
  /// Faulted on as many sweeps as `PendingActions.attemptLimit` allows; kept, and not started again.
  case skipped(proposal: UUID, fault: String?)
  /// The table could not be read, so nothing was swept.
  case unreadable(code: String)
}

/// `nf_local_pending_action`, a table of this device's own beside the vault: the apply records its card's actions in its content transaction, and each
/// action's transaction takes its index out, so a process that ended between the two leaves the row for the launch sweep.
enum PendingActions {
  static let table = "nf_local_pending_action"
  /// Sweeps that may start on a row before it is faulted for good; one killed mid-sweep counts, so an action that ends the process cannot loop the launch.
  static let attemptLimit = 3
  static let unsettledFault = "refinement.actions_unsettled"
  private static let definition = """
    CREATE TABLE IF NOT EXISTS nf_local_pending_action (
      proposal BLOB NOT NULL PRIMARY KEY, novel BLOB NOT NULL, actions TEXT NOT NULL, recorded_at INTEGER NOT NULL, attempts INTEGER NOT NULL, fault TEXT
    ) STRICT, WITHOUT ROWID
    """

  static func record(proposal: UUID, novel: UUID, actions: [Int], at now: Date, in database: Database) throws(StoreError) {
    guard !actions.isEmpty else { return }
    try execute {
      try database.execute(sql: definition)
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(table) (proposal, novel, actions, recorded_at, attempts) VALUES (?, ?, ?, ?, 0)",
        arguments: [proposal, novel, encode(actions), Int64(exactly: (now.timeIntervalSince1970 * 1000).rounded(.down)) ?? 0])
    }
  }

  /// Takes `index` out of the proposal's row, removing the row once nothing is left; a list that cannot be read is left to the sweep, which reads the card.
  static func settle(proposal: UUID, index: Int, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      guard let stored = try String.fetchOne(database, sql: "SELECT actions FROM \(table) WHERE proposal = ?", arguments: [proposal]),
        let actions = decode(stored)
      else { return }
      let left = actions.filter { $0 != index }
      if left.isEmpty {
        try database.execute(sql: "DELETE FROM \(table) WHERE proposal = ?", arguments: [proposal])
      } else if left != actions {
        try database.execute(sql: "UPDATE \(table) SET actions = ? WHERE proposal = ?", arguments: [encode(left), proposal])
      }
    }
  }

  /// Oldest first; a row whose proposal or novel cannot be read is stepped over and left as it is.
  static func rows(in database: Database) throws(StoreError) -> [PendingActionRow] {
    try execute {
      guard try database.tableExists(table) else { return [] }
      let sql = "SELECT proposal, novel, actions, attempts, fault FROM \(table) ORDER BY recorded_at, proposal"
      return try Row.fetchAll(database, sql: sql).compactMap(PendingActionRow.init(row:))
    }
  }

  static func forget(proposal: UUID, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE proposal = ?", arguments: [proposal])
    }
  }

  static func attempt(proposal: UUID, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "UPDATE \(table) SET attempts = attempts + 1 WHERE proposal = ?", arguments: [proposal])
    }
  }

  static func fault(proposal: UUID, code: String, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "UPDATE \(table) SET fault = ? WHERE proposal = ?", arguments: [code, proposal])
    }
  }

  fileprivate static func decode(_ stored: String) -> [Int]? {
    let parts = stored.split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
    guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
    return parts.compactMap { $0 }
  }

  private static func encode(_ actions: [Int]) -> String {
    Set(actions).sorted().map(String.init).joined(separator: ",")
  }

  private static func execute<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch {
      throw StoreError(projecting: error)
    }
  }
}

extension PendingActionRow {
  fileprivate init?(row: Row) {
    guard let proposal = try? row.decode(UUID.self, forColumn: "proposal"), let novel = try? row.decode(UUID.self, forColumn: "novel"),
      let attempts = try? row.decode(Int.self, forColumn: "attempts")
    else { return nil }
    let actions = (try? row.decode(String.self, forColumn: "actions")).flatMap(PendingActions.decode)
    self.init(proposal: proposal, novel: novel, actions: actions, attempts: attempts, fault: (try? row.decode(String?.self, forColumn: "fault")) ?? nil)
  }
}
