import Foundation
import GRDB
import ShadowStore

public struct NotebookQuery: Sendable, Equatable {
  public let novel: UUID
  public let filter: NotebookFilter

  public init(novel: UUID, filter: NotebookFilter = NotebookFilter()) {
    self.novel = novel
    self.filter = filter
  }
}

public struct NotebookCounts: Sendable, Equatable {
  public let active: Int
  public let superseded: Int
  public let withdrawn: Int
}

public struct NotebookEntries: Sendable, Equatable {
  public let entries: [NotebookEntry]
  public let sections: NotebookSections
  public let counts: NotebookCounts
  public let unreadable: Int
}

public struct NotebookContents: ReadModel {
  public let notebook: Derived<NotebookEntries>
  public let faults: [ReadFault]

  private static let tables = [NotebookEntryStateRow.databaseTableName]

  public static func load(_ query: NotebookQuery, in transaction: ReadTransaction) throws(StoreError) -> NotebookContents {
    let report = try ReadFaults(novel: query.novel, reading: tables, in: transaction)
    return NotebookContents(
      notebook: try report.section(tables) { () throws(StoreError) in try entries(query, in: transaction) },
      faults: report.relevant)
  }

  static func entries(_ query: NotebookQuery, in transaction: ReadTransaction) throws(StoreError) -> NotebookEntries {
    let novel = query.novel
    let states = try transaction.query { database in try NotebookEntryStateRow.filter(Column("novel") == novel).fetchAll(database) }
    var unreadable = try transaction.query { database in
      try IndexedRecord.filter(Column("novel") == novel && Column("kind") == NovelForgeKind.notebookEntry.rawValue && Column("status") == IndexedStatus.unreadable)
        .fetchCount(database)
    }
    var active = [AppendedEntry<NotebookEntryRecord>]()
    var stateByEntry = [UUID: NotebookEntryState]()
    for row in states where row.status == .active {
      guard let entry = try NotebookEntryRecord.read(id: row.entry, in: transaction).entry else {
        unreadable += 1
        continue
      }
      active.append(entry)
      stateByEntry[row.entry] = row.state
    }
    let ledger = NotebookLedger(
      entries: active.sorted(by: NotebookEntryRecord.chronologically).map { NotebookEntry(record: $0.record, clock: $0.clock, state: stateByEntry[$0.record.id] ?? .active) },
      unreadable: unreadable)
    let shown = ledger.notebook(matching: query.filter)
    let counts = NotebookCounts(
      active: states.filter { $0.status == .active }.count, superseded: states.filter { $0.status == .superseded }.count,
      withdrawn: states.filter { $0.status == .withdrawn }.count)
    return NotebookEntries(entries: shown, sections: NotebookSections(of: shown), counts: counts, unreadable: unreadable)
  }
}
