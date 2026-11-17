import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// One proposal change as its proposal reads it. Its key is a hash, so this layer records the proposal it belongs to, which a proposal subscribes by.
public struct ProposalChangeRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_proposal_change"

  public let key: EntityKey
  public let novel: UUID
  public let proposal: UUID
  public let index: Int
  public let isReadable: Bool
  public let status: StoredEnum<ProposalChangeStatus>?
  /// `ProposalChangeRecord.actionOutcome`: the stored result settles an action, whatever a concurrent applier wrote into `status` since.
  public let outcome: StoredEnum<ProposalChangeStatus>?
  public let hasUndo: Bool

  init(
    key: EntityKey, novel: UUID, proposal: UUID, index: Int, isReadable: Bool, status: StoredEnum<ProposalChangeStatus>? = nil,
    outcome: StoredEnum<ProposalChangeStatus>? = nil, hasUndo: Bool = false
  ) {
    self.key = key
    self.novel = novel
    self.proposal = proposal
    self.index = index
    self.isReadable = isReadable
    self.status = status
    self.outcome = outcome
    self.hasUndo = hasUndo
  }

  public init(row: Row) throws {
    self.init(
      key: try ChatColumns.key(row, "key"), novel: try row.decode(UUID.self, forColumn: "novel"), proposal: try row.decode(UUID.self, forColumn: "proposal"),
      index: try row.decode(Int.self, forColumn: "op"), isReadable: try row.decode(Bool.self, forColumn: "readable"), status: try ChatColumns.stored(row, "status"),
      outcome: try ChatColumns.stored(row, "outcome"), hasUndo: try row.decode(Bool.self, forColumn: "has_undo"))
  }

  public var ref: EntityRef { EntityRef(kind: NovelForgeKind.proposalChange.entityKind, key: key) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["key"] = key.rawValue
    container["novel"] = novel
    container["proposal"] = proposal
    container["op"] = index
    container["readable"] = isReadable
    container["status"] = status?.rawValue
    container["outcome"] = outcome?.rawValue
    container["has_undo"] = hasUndo
  }
}

public struct ProposalChangeRowDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_proposal_change (
      key TEXT PRIMARY KEY, novel BLOB NOT NULL, proposal BLOB NOT NULL, op INTEGER NOT NULL, readable INTEGER NOT NULL, status TEXT, outcome TEXT, has_undo INTEGER NOT NULL
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_proposal_change_proposal ON nf_derived_proposal_change (proposal);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.records([.proposalChange]) { [$0] }]
  }

  public static func key(of output: ProposalChangeRow) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<ProposalChangeRow> {
    ProposalChangeRow.filter(Column("key") == ref.key.rawValue)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .proposalChange))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ProposalChangeRow] {
    let state = try context.records.state(of: ref, scope: .vault)
    switch ProposalChangeRecord.reading(state, of: ref) {
    case .absent:
      return []
    case .readable(let entry):
      let change = entry.record
      return [
        ProposalChangeRow(
          key: ref.key, novel: change.novel, proposal: change.proposal, index: change.index, isReadable: true, status: change.status, outcome: change.actionOutcome,
          hasUndo: change.undo != nil)
      ]
    case .unreadable:
      guard let state, let key = try? NovelForgeKey(reading: state, of: ref), case .proposalChange(let proposal, let index) = key.components else { return [] }
      return [ProposalChangeRow(key: ref.key, novel: key.novel, proposal: proposal, index: index, isReadable: false)]
    }
  }
}
