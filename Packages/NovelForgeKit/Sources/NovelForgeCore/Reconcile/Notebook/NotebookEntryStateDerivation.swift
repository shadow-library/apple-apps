import Foundation
import GRDB
import ShadowStore

public struct NotebookEntryStateRow: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_notebook_entry"

  public let entry: UUID
  public let novel: UUID
  public let status: LedgerEntryStatus
  public let successor: UUID?
  public let withdrawal: UUID?

  init(entry: UUID, novel: UUID, state: NotebookEntryState) {
    self.entry = entry
    self.novel = novel
    status = state.status
    successor = state.successor
    withdrawal = state.withdrawal
  }

  public var state: NotebookEntryState { NotebookEntryState(successor: successor, withdrawal: withdrawal) }
}

// One row per readable entry of the novel. Subscribes to the record index, which changes whenever an entry or a withdrawal does.
public struct NotebookEntryStateDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_notebook_entry (
      entry BLOB PRIMARY KEY, novel BLOB NOT NULL, status TEXT NOT NULL, successor BLOB, withdrawal BLOB
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_notebook_entry_novel ON nf_derived_notebook_entry (novel, status);
    """

  private static let kinds: [NovelForgeKind] = [.notebookEntry, .notebookWithdrawal]

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [.outputs(of: RecordIndexDerivation.self) { row in Self.kinds.contains(row.kind) ? row.novel.map { [$0] } ?? [] : [] }]
  }

  public static func key(of output: NotebookEntryStateRow) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<NotebookEntryStateRow> {
    NotebookEntryStateRow.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(IndexedRecord.filter(Self.kinds.map(\.rawValue).contains(Column("kind")))).compactMap(\.novel))
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [NotebookEntryStateRow] {
    let rows = try context.fetchAll(IndexedRecord.filter(Column("novel") == novel && Self.kinds.map(\.rawValue).contains(Column("kind"))))
    var entries = [AppendedEntry<NotebookEntryRecord>]()
    var withdrawals = [AppendedEntry<NotebookWithdrawalRecord>]()
    for row in rows {
      switch row.kind {
      case .notebookEntry: if let entry = try NotebookEntryRecord.read(row.ref, in: context.records).entry { entries.append(entry) }
      case .notebookWithdrawal: if let withdrawal = try NotebookWithdrawalRecord.read(row.ref, in: context.records).entry { withdrawals.append(withdrawal) }
      default: continue
      }
    }
    let states = NotebookResolution.resolve(entries: entries, withdrawals: withdrawals)
    return entries.map { NotebookEntryStateRow(entry: $0.record.id, novel: novel, state: states[$0.record.id] ?? .active) }
  }
}
