import Foundation
import GRDB
import ShadowStore

public enum NovelPresence: Sendable, Equatable {
  case missing
  case unreadable
  case present(NovelRecord)
}

public struct MilestoneTally: Sendable, Equatable {
  public let open: Int
  public let planned: Int
  public let reached: Int
}

public struct BibleTally: Sendable, Equatable {
  public let pages: Int
  public let entities: Int
}

public struct NovelOverview: ReadModel {
  public let presence: NovelPresence
  public let chapters: Derived<ChapterTally>
  public let activeVolume: Derived<VolumeRecord?>
  public let milestones: Derived<MilestoneTally>
  public let notebookEntries: Derived<Int>
  public let bible: Derived<BibleTally>
  public let faults: [ReadFault]

  private static let volumeTables = [VolumeStateEntry.databaseTableName]
  private static let milestoneTables = [MilestoneStateEntry.databaseTableName]
  private static let notebookTables = [NotebookEntryStateRow.databaseTableName]
  private static let bibleTables = [IndexedRecord.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> NovelOverview {
    let tables = ChapterTally.tables + volumeTables + milestoneTables + notebookTables + bibleTables
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    return NovelOverview(
      presence: try presence(of: novel, in: transaction),
      chapters: try report.section(ChapterTally.tables) { () throws(StoreError) in try ChapterTally.load(novel: novel, in: transaction) },
      activeVolume: try report.section(volumeTables) { () throws(StoreError) in try activeVolume(of: novel, in: transaction) },
      milestones: try report.section(milestoneTables) { () throws(StoreError) in try milestones(of: novel, in: transaction) },
      notebookEntries: try report.section(notebookTables) { () throws(StoreError) in try notebookEntries(of: novel, in: transaction) },
      bible: try report.section(bibleTables) { () throws(StoreError) in try bible(of: novel, in: transaction) },
      faults: report.relevant)
  }

  private static func presence(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> NovelPresence {
    switch try NovelRecord.read(id: novel, in: transaction) {
    case .absent: .missing
    case .unreadable: .unreadable
    case .readable(let entry): entry.isRemoved ? .missing : .present(entry.record)
    }
  }

  private static func activeVolume(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> VolumeRecord? {
    let active = try transaction.query { database in
      try VolumeStateEntry.filter(Column("novel") == novel && Column("state") == VolumeState.active.rawValue).fetchOne(database)
    }
    guard let active, case .readable(let entry) = try VolumeRecord.read(active.ref, in: transaction), !entry.isRemoved else { return nil }
    return entry.record
  }

  private static func milestones(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> MilestoneTally {
    let counts = try transaction.query { database in
      try Row.fetchAll(database, sql: "SELECT state, COUNT(*) AS total FROM nf_derived_milestone_state WHERE novel = ? GROUP BY state", arguments: [novel])
    }
    var tally = [String: Int]()
    for row in counts { tally[row["state"]] = row["total"] }
    return MilestoneTally(
      open: tally[MilestoneState.open.rawValue] ?? 0, planned: tally[MilestoneState.planned.rawValue] ?? 0, reached: tally[MilestoneState.reached.rawValue] ?? 0)
  }

  private static func notebookEntries(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> Int {
    try NotebookContents.entries(NotebookQuery(novel: novel), in: transaction).entries.count
  }

  private static func bible(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> BibleTally {
    func live(_ kind: NovelForgeKind) throws(StoreError) -> Int {
      try transaction.query { database in
        try IndexedRecord.filter(Column("novel") == novel && Column("kind") == kind.rawValue && Column("status") == IndexedStatus.live).fetchCount(database)
      }
    }
    return BibleTally(pages: try live(.page), entities: try live(.entity))
  }
}
