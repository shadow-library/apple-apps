import Foundation
import GRDB
import ShadowStore

/// A staging transaction that committed for a reply, recorded in that transaction: the applied side, which says whether cards were to follow it, or the
/// cards, with no proposal when every card op was left out.
enum TurnStagingStep: Equatable, Sendable {
  case applied(proposal: UUID, cardsFollow: Bool)
  case cards(proposal: UUID?)
}

/// `nf_local_turn_step`, a table of this device's own beside the vault: which of a reply's staging transactions committed, so a turn stopped before it saved
/// what staging left knows exactly what did, and stages nothing twice.
enum TurnStagingMarks {
  static let table = "nf_local_turn_step"
  private static let definition = """
    CREATE TABLE IF NOT EXISTS nf_local_turn_step (
      turn BLOB NOT NULL, step TEXT NOT NULL, session BLOB NOT NULL, proposal BLOB, cards_follow INTEGER NOT NULL, PRIMARY KEY (turn, step)
    ) STRICT, WITHOUT ROWID
    """

  static func record(_ step: TurnStagingStep, reply: UUID, session: UUID, in database: Database) throws(StoreError) {
    let (name, proposal, cardsFollow): (String, UUID?, Bool) =
      switch step {
      case .applied(let proposal, let cardsFollow): ("applied", proposal, cardsFollow)
      case .cards(let proposal): ("cards", proposal, false)
      }
    try execute {
      try database.execute(sql: definition)
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(table) (turn, step, session, proposal, cards_follow) VALUES (?, ?, ?, ?, ?)",
        arguments: [reply, name, session, proposal, cardsFollow])
    }
  }

  /// The steps that committed for `reply`; nil when one cannot be read, since a guess could stage changes twice.
  static func steps(of reply: UUID, in database: Database) throws(StoreError) -> [TurnStagingStep]? {
    try execute { () throws -> [TurnStagingStep]? in
      guard try database.tableExists(table) else { return [] }
      var steps = [TurnStagingStep]()
      for row in try Row.fetchAll(database, sql: "SELECT step, proposal, cards_follow FROM \(table) WHERE turn = ? ORDER BY step", arguments: [reply]) {
        let stored: DatabaseValue = row["proposal"]
        let proposal = UUID.fromDatabaseValue(stored)
        guard let name = try? row.decode(String.self, forColumn: "step"), let cardsFollow = try? row.decode(Bool.self, forColumn: "cards_follow"),
          stored.isNull || proposal != nil
        else { return nil }
        switch (name, proposal) {
        case ("applied", let proposal?): steps.append(.applied(proposal: proposal, cardsFollow: cardsFollow))
        case ("cards", _): steps.append(.cards(proposal: proposal))
        default: return nil
        }
      }
      return steps
    }
  }

  static func forget(turn: UUID, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE turn = ?", arguments: [turn])
    }
  }

  static func forget(session: UUID, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE session = ?", arguments: [session])
    }
  }

  private static func execute<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch {
      throw StoreError(projecting: error)
    }
  }
}
