import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/refinement/proposal.service.ts:72, :398-409
enum ProposalDiscard {
  /// proposal.service.ts:72 (DISCARDABLE = pending | conflicted): `conflicted` is derived, never stored, so a card is discardable while its merged decision is
  /// pending. A superseded, discarded or applied card is refused, as is a decision this version does not know.
  static func isDiscardable(_ decision: StoredEnum<ProposalDecision>?) -> Bool {
    decision == .known(.pending)
  }

  /// proposal.service.ts:398: the decision read in this transaction is the source of truth, so an apply or supersession that arrived meanwhile settles the
  /// card first. A card this device cannot read is still set aside, by its stored decision and novel alone.
  @discardableResult
  static func discard(_ proposal: UUID, novel: UUID, in transaction: inout WriteTransaction) throws(ProposalDecisionError) -> ChangeRecord {
    let ref = ProposalRecord.ref(id: proposal)
    let snapshot: ProposalSnapshot?
    do throws(StoreError) {
      snapshot = ProposalSnapshot(ref, try transaction.state(of: ref, scope: .vault))
    } catch {
      throw .store(error)
    }
    guard let snapshot, snapshot.novel == novel else { throw .notFound(proposal) }
    guard isDiscardable(snapshot.decision) else { throw .notPending(snapshot.decision) }
    let outcome: DecisionOutcome
    do throws(StoreError) {
      outcome = try ProposalRecord.dismiss(ref, as: .discarded, in: &transaction)
    } catch {
      throw .store(error)
    }
    switch outcome {
    case .raised(let change): return change
    case .unchanged(let decision): throw .notPending(decision)
    }
  }
}

extension VaultStore {
  /// Discards a pending card (RFN_001 when the novel holds no such proposal, RFN_002 when it is no longer pending).
  public func discardProposal(_ proposal: UUID, novel: UUID) async throws(ProposalDecisionError) {
    do {
      _ = try await write { transaction in try ProposalDiscard.discard(proposal, novel: novel, in: &transaction) }
    } catch {
      if case .aborted(let cause) = error, let decision = cause as? ProposalDecisionError { throw decision }
      throw .store(error)
    }
  }
}
