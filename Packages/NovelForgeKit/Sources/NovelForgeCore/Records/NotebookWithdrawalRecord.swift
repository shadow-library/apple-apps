import Foundation
import ShadowCore
import ShadowStore

extension NotebookWithdrawalMember: FieldName {}

// apps/novel-forge-server/src/modules/ledger/ledger.service.ts:146 withdraws an entry with the author's reason
public struct NotebookWithdrawalRecord: AppendedRecord {
  public static let kind = NovelForgeKind.notebookWithdrawal
  public static let novelMember = NotebookWithdrawalMember.novel

  public let id: UUID
  public let novel: UUID
  public let entry: UUID
  public let reason: String
  public private(set) var unrecognised: [String: JSONValue]

  public init(id: UUID = UUID(), novel: UUID, entry: UUID, reason: String) {
    self.id = id
    self.novel = novel
    self.entry = entry
    self.reason = reason
    unrecognised = [:]
  }

  public init(id: UUID, reading reader: FieldReader<NotebookWithdrawalMember>) throws(UnreadableReason) {
    self.init(id: id, novel: try reader.required(.novel), entry: try reader.required(.entry), reason: try reader.required(.reason))
    unrecognised = reader.unrecognised
  }

  public var members: RecordFields<NotebookWithdrawalMember> {
    var fields = RecordFields<NotebookWithdrawalMember>()
    fields.put(.novel, novel)
    fields.put(.entry, entry)
    fields.put(.reason, reason)
    return fields
  }
}

extension NotebookEntryRecord {
  public static func withdrawals(of entries: [NotebookEntryRecord], among withdrawals: [AppendedEntry<NotebookWithdrawalRecord>]) -> [UUID: AppendedEntry<
    NotebookWithdrawalRecord
  >] {
    let novels = Dictionary(entries.map { ($0.id, $0.novel) }) { first, _ in first }
    var earliest = [UUID: AppendedEntry<NotebookWithdrawalRecord>]()
    for withdrawal in withdrawals.sorted(by: NotebookWithdrawalRecord.chronologically) where novels[withdrawal.record.entry] == withdrawal.record.novel {
      if earliest[withdrawal.record.entry] == nil { earliest[withdrawal.record.entry] = withdrawal }
    }
    return earliest
  }

  public static func withdrawals<Transaction: StateReading & ~Copyable>(novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> [UUID: AppendedEntry<
    NotebookWithdrawalRecord
  >] {
    withdrawals(of: try listing(novel: novel, in: transaction).records, among: try NotebookWithdrawalRecord.listing(novel: novel, in: transaction).entries)
  }
}
