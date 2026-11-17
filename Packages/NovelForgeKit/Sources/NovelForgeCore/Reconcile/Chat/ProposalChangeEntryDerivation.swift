import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// What one index of a card amounts to, as `ProposalChangeRecord.changes(of:in:)` reads it, plus the change's own state once it is recorded.
public enum ProposalChangeEntryState: String, Sendable, CaseIterable, DatabaseValueConvertible {
  case applied
  case pending
  case failed
  case reverted
  /// The first applier did not select it.
  case declined
  /// Applied, and selected (or the selection cannot be read), but its record has not arrived.
  case awaiting
  case notApplied = "not_applied"
  /// Recorded, but the record cannot be read; shown as such, never hidden, since it may hold an undo.
  case unreadable
  /// Recorded with a status this version does not know.
  case unrecognised
  /// Never stored: the history's state of a rewrite with no undo that several changes may have carried, standing in a mix of applied and reverted.
  case uncertain
}

public struct ProposalEntryRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_proposal_entry"

  public let proposal: UUID
  public let index: Int
  public let state: ProposalChangeEntryState
  public let isAction: Bool
  public let hasUndo: Bool

  init(proposal: UUID, index: Int, state: ProposalChangeEntryState, isAction: Bool, hasUndo: Bool) {
    self.proposal = proposal
    self.index = index
    self.state = state
    self.isAction = isAction
    self.hasUndo = hasUndo
  }

  public init(row: Row) throws {
    self.init(
      proposal: try row.decode(UUID.self, forColumn: "proposal"), index: try row.decode(Int.self, forColumn: "op"),
      state: try row.decode(ProposalChangeEntryState.self, forColumn: "state"), isAction: try row.decode(Bool.self, forColumn: "action"),
      hasUndo: try row.decode(Bool.self, forColumn: "has_undo"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["proposal"] = proposal
    container["op"] = index
    container["state"] = state
    container["action"] = isAction
    container["has_undo"] = hasUndo
  }
}

// apps/novel-forge-server/src/modules/refinement/proposal.service.ts:264-300 lists each op's result; here an index's record is its result, and an action
// reads its settled outcome (proposal-apply.service.ts:259-280) while a content change reads its status register, which undo and redo move.
public struct ProposalChangeEntryDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_proposal_entry (
      proposal BLOB NOT NULL, op INTEGER NOT NULL, state TEXT NOT NULL, action INTEGER NOT NULL, has_undo INTEGER NOT NULL, PRIMARY KEY (proposal, op)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [
      .records([.proposal]) { [$0] },
      .outputs(of: ProposalChangeRowDerivation.self) { [NovelForgeKey.proposal($0.proposal)] },
    ]
  }

  public static func key(of output: ProposalEntryRow) -> EntityRef { NovelForgeKey.proposal(output.proposal) }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<ProposalEntryRow> {
    guard let proposal = ChatColumns.id(of: ref, .proposal) else { return ProposalEntryRow.filter(sql: "0") }
    return ProposalEntryRow.filter(Column("proposal") == proposal)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .proposal))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ProposalEntryRow] {
    guard let proposal = ProposalSnapshot(ref, try context.records.state(of: ref, scope: .vault)), let card = proposal.card else { return [] }
    let rows = try context.fetchAll(ProposalChangeRow.filter(Column("proposal") == proposal.id && Column("novel") == proposal.novel))
    let recorded = Dictionary(rows.map { ($0.index, $0) }) { first, _ in first }
    return card.changeSet.indices.map { index in
      let isAction = proposal.isAction(at: index)
      guard let row = recorded[index] else {
        return ProposalEntryRow(proposal: proposal.id, index: index, state: Self.unrecorded(index, of: proposal), isAction: isAction, hasUndo: false)
      }
      return ProposalEntryRow(proposal: proposal.id, index: index, state: Self.state(of: row, isAction: isAction), isAction: isAction, hasUndo: row.hasUndo)
    }
  }

  private static func state(of row: ProposalChangeRow, isAction: Bool) -> ProposalChangeEntryState {
    guard row.isReadable else { return .unreadable }
    switch (isAction ? row.outcome : row.status)?.known {
    case .applied: return .applied
    case .pending: return .pending
    case .failed: return .failed
    case .reverted: return .reverted
    case nil: return .unrecognised
    }
  }

  private static func unrecorded(_ index: Int, of proposal: ProposalSnapshot) -> ProposalChangeEntryState {
    guard proposal.decision == .known(.applied) else { return .notApplied }
    guard let application = proposal.application, !application.selected.contains(index) else { return .awaiting }
    return .declined
  }
}
