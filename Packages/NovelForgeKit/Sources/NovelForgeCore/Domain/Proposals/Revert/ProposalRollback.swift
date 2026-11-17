import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/refinement/proposal-revert.service.ts:54-59
struct ProposalRollbackResult: Sendable, Equatable {
  struct Reverted: Sendable, Equatable {
    let proposal: UUID
    let result: ProposalRevertResult
  }

  var reverted: [Reverted] = []
  var skipped: [UUID] = []
  var stoppedAt: UUID?
  var conflict: ProposalRevertError?
}

/// What a rollback after a proposal walks: the novel's later applies, newest first, by the clock of their first-writer-wins `applied` (the first applier's).
struct RollbackPlan: Sendable, Equatable {
  /// Applies with a change still applied, or one this device cannot read or awaits, whose revert then refuses and stops the rollback; in this order.
  let revertible: [UUID]
  /// Applies that hold no undo at all and nothing this device cannot read: actions only.
  let skipped: [UUID]
}

enum ProposalRollback {
  // proposal-revert.service.ts:271-291: the anchor must be applied (RFN_001, RFN_007); ties on the clock break by id. An apply whose changes are all undone
  // already is a reverted proposal there and is not listed.
  static func plan(after anchor: UUID, novel: UUID, in transaction: ReadTransaction) throws(ProposalRevertError) -> RollbackPlan {
    let anchorTurn = try ProposalTurn.load(anchor, novel: novel, in: transaction)
    guard anchorTurn.isApplied, let anchorClock = try appliedClock(anchor, in: transaction) else { throw .notRevertible }
    let proposals = try revertStore { () throws(StoreError) in
      ProposalRecord.collecting(try transaction.states(ofKind: ProposalRecord.kind.entityKind, scope: .vault), owner: novel)
    }
    var newer = [(id: UUID, clock: HLCTimestamp)]()
    for proposal in proposals.live where proposal.decision == .known(.applied) && proposal.id != anchor {
      guard let clock = try appliedClock(proposal.id, in: transaction) else { continue }
      if clock > anchorClock || (clock == anchorClock && proposal.id.uuidString > anchor.uuidString) { newer.append((proposal.id, clock)) }
    }
    newer.sort { $0.clock == $1.clock ? $0.id.uuidString > $1.id.uuidString : $0.clock > $1.clock }

    var revertible = [UUID]()
    var skipped = [UUID]()
    for (id, _) in newer {
      let turn = try ProposalTurn.load(id, novel: novel, in: transaction)
      let unreadable = turn.unsettled.contains { $0.entry != .declined }
      if unreadable || !turn.indexes(.applied).isEmpty {
        revertible.append(id)
      } else if !turn.entries.indices.contains(where: { turn.undoable($0) != nil }) {
        skipped.append(id)
      }
    }
    return RollbackPlan(revertible: revertible, skipped: skipped)
  }

  private static func appliedClock(_ id: UUID, in transaction: ReadTransaction) throws(ProposalRevertError) -> HLCTimestamp? {
    let state = try revertStore { () throws(StoreError) in try transaction.state(of: ProposalRecord.ref(id: id), scope: .vault) }
    guard case .record(let record)? = state else { return nil }
    return record[field: ProposalField.applied.rawValue]?.clock
  }
}

extension VaultStore {
  /// proposal-op-undo.service.ts:22: undoes change `index` of an automatic chat apply in one transaction, turning an undone idea down in the Notebook.
  func undoProposalChange(_ id: UUID, index: Int, idea: IdeaUndoChoice = IdeaUndoChoice(), context: ProposalRevertContext) async throws(ProposalRevertError)
    -> ProposalChangeToggle
  {
    try await writeRevert { transaction throws(ProposalRevertError) in
      try ProposalRevert.undo(proposal: id, index: index, idea: idea, context: context, in: &transaction)
    }
  }

  /// proposal-op-undo.service.ts:30: redoes change `index` in one transaction, withdrawing the Notebook rejection of a redone idea.
  func redoProposalChange(_ id: UUID, index: Int, context: ProposalRevertContext) async throws(ProposalRevertError) -> ProposalChangeToggle {
    try await writeRevert { transaction throws(ProposalRevertError) in try ProposalRevert.redo(proposal: id, index: index, context: context, in: &transaction) }
  }

  /// proposal-revert.service.ts:84: every applied change of the card undone in one transaction.
  func revertProposal(_ id: UUID, context: ProposalRevertContext) async throws(ProposalRevertError) -> ProposalRevertResult {
    try await writeRevert { transaction throws(ProposalRevertError) in try ProposalRevert.revert(proposal: id, context: context, in: &transaction) }
  }

  /// proposal-revert.service.ts:271-311: reverts each later apply, newest first, one transaction each, and stops at the first refusal.
  func rollbackProposals(after anchor: UUID, context: ProposalRevertContext) async throws(ProposalRevertError) -> ProposalRollbackResult {
    let novel = context.novel
    let plan = try await readRevert { transaction throws(ProposalRevertError) in try ProposalRollback.plan(after: anchor, novel: novel, in: transaction) }
    var result = ProposalRollbackResult(skipped: plan.skipped)
    for id in plan.revertible {
      do throws(ProposalRevertError) {
        result.reverted.append(ProposalRollbackResult.Reverted(proposal: id, result: try await revertProposal(id, context: context)))
      } catch {
        result.stoppedAt = id
        result.conflict = error
        break
      }
    }
    return result
  }

  /// proposal.service.ts:347: what relies on the records the card's applied changes, or change `index` alone, wrote.
  func undoImpact(of id: UUID, index: Int? = nil, novel: UUID) async throws(ProposalRevertError) -> UndoImpact {
    try await readRevert { transaction throws(ProposalRevertError) in try UndoImpacts.impact(proposal: id, index: index, novel: novel, in: transaction) }
  }

  private func writeRevert<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(ProposalRevertError) -> T) async throws(ProposalRevertError) -> T {
    do {
      return try await write { transaction in try body(&transaction) }
    } catch {
      if case .aborted(let cause) = error, let revert = cause as? ProposalRevertError { throw revert }
      throw .store(error)
    }
  }

  private func readRevert<T: Sendable>(_ body: @Sendable (ReadTransaction) throws(ProposalRevertError) -> T) async throws(ProposalRevertError) -> T {
    do {
      return try await read { transaction in try body(transaction) }
    } catch {
      if case .aborted(let cause) = error, let revert = cause as? ProposalRevertError { throw revert }
      throw .store(error)
    }
  }
}
