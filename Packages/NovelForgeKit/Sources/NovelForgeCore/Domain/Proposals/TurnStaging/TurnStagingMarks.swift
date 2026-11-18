import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// A staging transaction that committed for a reply, recorded in that transaction: the applied side, which says whether cards were to follow it, or the
/// cards, with no proposal when every card op was left out.
enum TurnStagingStep: Equatable, Sendable {
  case applied(proposal: UUID, cardsFollow: Bool)
  case cards(proposal: UUID?)
}

/// What the reply records of a staging besides its proposals, as the staging ends when no later step commits.
struct TurnStagingNotes: Equatable, Sendable {
  var applyNote: String?
  var held: TurnHoldReason?
  var replyNote: String?

  init(applyNote: String? = nil, held: TurnHoldReason? = nil, replyNote: String? = nil) {
    self.applyNote = applyNote
    self.held = held
    self.replyNote = replyNote
  }

  fileprivate var json: JSONValue {
    let fields: [(String, String?)] = [("applyNote", applyNote), ("held", held?.rawValue), ("replyNote", replyNote)]
    return .object(Dictionary(uniqueKeysWithValues: fields.compactMap { name, value in value.map { (name, JSONValue.string($0)) } }))
  }

  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, fields.values.allSatisfy({ $0.stringValue != nil }) else { return nil }
    let held = fields["held"]?.stringValue
    guard held == nil || held.flatMap(TurnHoldReason.init(rawValue:)) != nil else { return nil }
    self.init(applyNote: fields["applyNote"]?.stringValue, held: held.flatMap(TurnHoldReason.init(rawValue:)), replyNote: fields["replyNote"]?.stringValue)
  }
}

/// A step as it was recorded; `notes` is nil for a step recorded before steps carried them, or whose notes cannot be read.
struct TurnStagingMark: Equatable, Sendable {
  let step: TurnStagingStep
  let notes: TurnStagingNotes?
}

/// `nf_local_turn_step`, a table of this device's own beside the vault: which of a reply's staging transactions committed, with the notes the reply takes
/// if that step is its last, so a turn stopped before it saved what staging left knows exactly what did, stages nothing twice and says what it would have.
enum TurnStagingMarks {
  static let table = "nf_local_turn_step"
  private static let notesColumn = "notes"
  private static let definition = """
    CREATE TABLE IF NOT EXISTS nf_local_turn_step (
      turn BLOB NOT NULL, step TEXT NOT NULL, session BLOB NOT NULL, proposal BLOB, cards_follow INTEGER NOT NULL, notes BLOB, PRIMARY KEY (turn, step)
    ) STRICT, WITHOUT ROWID
    """

  static func record(_ step: TurnStagingStep, notes: TurnStagingNotes? = nil, reply: UUID, session: UUID, in database: Database) throws(StoreError) {
    let (name, proposal, cardsFollow): (String, UUID?, Bool) =
      switch step {
      case .applied(let proposal, let cardsFollow): ("applied", proposal, cardsFollow)
      case .cards(let proposal): ("cards", proposal, false)
      }
    try execute {
      try database.execute(sql: definition)
      // a table made before steps carried their notes
      if try !hasNotes(database) { try database.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(notesColumn) BLOB") }
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(table) (turn, step, session, proposal, cards_follow, notes) VALUES (?, ?, ?, ?, ?, ?)",
        arguments: [reply, name, session, proposal, cardsFollow, notes.map { CanonicalJSON.encode($0.json) }])
    }
  }

  /// The steps that committed for `reply`; nil when one cannot be read, since a guess could stage changes twice.
  static func steps(of reply: UUID, in database: Database) throws(StoreError) -> [TurnStagingStep]? {
    try marks(of: reply, in: database)?.map(\.step)
  }

  /// `steps(of:)` with the notes each step recorded, in the order the steps commit.
  static func marks(of reply: UUID, in database: Database) throws(StoreError) -> [TurnStagingMark]? {
    try execute { () throws -> [TurnStagingMark]? in
      guard try database.tableExists(table) else { return [] }
      let notes = try hasNotes(database) ? notesColumn : "NULL AS \(notesColumn)"
      var marks = [TurnStagingMark]()
      let rows = try Row.fetchAll(database, sql: "SELECT step, proposal, cards_follow, \(notes) FROM \(table) WHERE turn = ? ORDER BY step", arguments: [reply])
      for row in rows {
        let stored: DatabaseValue = row["proposal"]
        let proposal = UUID.fromDatabaseValue(stored)
        guard let name = try? row.decode(String.self, forColumn: "step"), let cardsFollow = try? row.decode(Bool.self, forColumn: "cards_follow"),
          stored.isNull || proposal != nil
        else { return nil }
        let recorded = (try? row.decode(Data.self, forColumn: notesColumn)).flatMap { try? CanonicalJSON.decode($0) }.flatMap(TurnStagingNotes.init(json:))
        switch (name, proposal) {
        case ("applied", let proposal?): marks.append(TurnStagingMark(step: .applied(proposal: proposal, cardsFollow: cardsFollow), notes: recorded))
        case ("cards", _): marks.append(TurnStagingMark(step: .cards(proposal: proposal), notes: recorded))
        default: return nil
        }
      }
      return marks
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

  private static func hasNotes(_ database: Database) throws -> Bool {
    try database.columns(in: table).contains { $0.name == notesColumn }
  }

  private static func execute<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch {
      throw StoreError(projecting: error)
    }
  }
}
