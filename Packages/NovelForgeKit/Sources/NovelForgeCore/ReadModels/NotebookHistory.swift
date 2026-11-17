import Foundation
import GRDB
import ShadowStore

public struct NotebookLedgerHistory: Sendable, Equatable {
  public let ledger: NotebookLedger
  public let counts: NotebookCounts
  private let byId: [UUID: NotebookEntry]
  private let reasons: [UUID: String]

  init(ledger: NotebookLedger, reasons: [UUID: String]) {
    self.ledger = ledger
    self.reasons = reasons
    byId = Dictionary(ledger.entries.map { ($0.id, $0) }) { first, _ in first }
    let statuses = ledger.entries.map(\.status)
    counts = NotebookCounts(
      active: statuses.count { $0 == .active }, superseded: statuses.count { $0 == .superseded }, withdrawn: statuses.count { $0 == .withdrawn })
  }

  public func entry(_ id: UUID) -> NotebookEntry? { byId[id] }

  public func successor(of entry: NotebookEntry) -> NotebookEntry? {
    entry.state.successor.flatMap { byId[$0] }
  }

  public func predecessor(of entry: NotebookEntry) -> NotebookEntry? {
    entry.record.supersedes.flatMap { byId[$0] }
  }

  public func reason(for entry: NotebookEntry) -> String? { reasons[entry.id] }
}

public struct NotebookHistory: ReadModel {
  public let notebook: Derived<NotebookLedgerHistory>
  public let faults: [ReadFault]

  private static let tables = [NotebookEntryStateRow.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> NotebookHistory {
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    return NotebookHistory(notebook: try report.section(tables) { () throws(StoreError) in try history(of: novel, in: transaction) }, faults: report.relevant)
  }

  private static func history(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> NotebookLedgerHistory {
    let states = try transaction.query { database in try NotebookEntryStateRow.filter(Column("novel") == novel).fetchAll(database) }
    var unreadable = try transaction.query { database in
      try IndexedRecord.filter(Column("novel") == novel && Column("kind") == NovelForgeKind.notebookEntry.rawValue && Column("status") == IndexedStatus.unreadable)
        .fetchCount(database)
    }
    var entries = [AppendedEntry<NotebookEntryRecord>]()
    var stateByEntry = [UUID: NotebookEntryState]()
    var reasons = [UUID: String]()
    for row in states {
      guard let entry = try NotebookEntryRecord.read(id: row.entry, in: transaction).entry else {
        unreadable += 1
        continue
      }
      entries.append(entry)
      stateByEntry[row.entry] = row.state
      guard let withdrawal = row.withdrawal, let found = try NotebookWithdrawalRecord.read(id: withdrawal, in: transaction).entry else { continue }
      reasons[row.entry] = found.record.reason
    }
    let ledger = NotebookLedger(
      entries: entries.sorted(by: NotebookEntryRecord.chronologically).map { NotebookEntry(record: $0.record, clock: $0.clock, state: stateByEntry[$0.record.id] ?? .active) },
      unreadable: unreadable)
    return NotebookLedgerHistory(ledger: ledger, reasons: reasons)
  }
}
