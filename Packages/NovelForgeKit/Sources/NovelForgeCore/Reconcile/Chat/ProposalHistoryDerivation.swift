import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// An applied proposal's place in the novel's change history: when it was applied, by the clock of the first applier's `applied` object, or of the decision
/// when that object is missing.
public struct ProposalHistoryRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_proposal_history"

  public let proposal: UUID
  public let novel: UUID
  public let applied: HLCTimestamp

  init(proposal: UUID, novel: UUID, applied: HLCTimestamp) {
    self.proposal = proposal
    self.novel = novel
    self.applied = applied
  }

  public init(row: Row) throws {
    self.init(
      proposal: try row.decode(UUID.self, forColumn: "proposal"), novel: try row.decode(UUID.self, forColumn: "novel"),
      applied: try ChatColumns.clock(row, "applied"))
  }

  public var ref: EntityRef { NovelForgeKey.proposal(proposal) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["proposal"] = proposal
    container["novel"] = novel
    container["applied"] = applied.description
  }
}

// apps/novel-forge-server/src/modules/refinement/proposal.service.ts:258-306 lists applied and reverted proposals, newest apply first; a revert here is each
// change reverted while the decision stays applied, so every applied proposal has a row, a card this version cannot read included.
public struct ProposalHistoryDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_proposal_history (
      proposal BLOB PRIMARY KEY, novel BLOB NOT NULL, applied TEXT NOT NULL
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_proposal_history_novel ON nf_derived_proposal_history (novel);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.records([.proposal]) { [$0] }]
  }

  public static func key(of output: ProposalHistoryRow) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<ProposalHistoryRow> {
    guard let proposal = ChatColumns.id(of: ref, .proposal) else { return ProposalHistoryRow.filter(sql: "0") }
    return ProposalHistoryRow.filter(Column("proposal") == proposal)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .proposal))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ProposalHistoryRow] {
    let state = try context.records.state(of: ref, scope: .vault)
    guard let proposal = ProposalSnapshot(ref, state), proposal.decision == .known(.applied), case .record(let record)? = state else { return [] }
    let stamp = record[field: ProposalField.applied.rawValue].flatMap { $0.value.isNull ? nil : $0 } ?? record[field: ProposalField.decision.rawValue]
    guard let applied = stamp?.clock else { return [] }
    return [ProposalHistoryRow(proposal: proposal.id, novel: proposal.novel, applied: applied)]
  }
}
