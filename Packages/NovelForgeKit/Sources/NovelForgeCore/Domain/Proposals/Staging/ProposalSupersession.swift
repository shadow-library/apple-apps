import Foundation
import GRDB
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/refinement/proposal.service.ts:80-88, :214-234
enum ProposalSupersession {
  // proposal.service.ts:81: what a chat stages itself; a card brought into the chat from elsewhere is not the chat's own work to replace
  static let chatStagedKinds: [ProposalKind] = [.chat, .hub, .chapterPlan, .organise]

  /// proposal.service.ts:224-229: an older card is replaced when it shares an action decision with the newer one, or a ref the two do not both rewrite passage
  /// by passage at standing, separate places. Only operations this version reads take part, so a card it cannot fully read is kept rather than replaced.
  static func overlaps(older: [ChangeOp], newer: [ChangeOp], drafts: [Int: AnchorDraft]) -> Bool {
    let decisions = Set(actionDecisionKeys(newer).map { JSString($0) })
    if actionDecisionKeys(older).contains(where: { decisions.contains(JSString($0)) }) { return true }
    let refs = Set(changeSetRefs(newer).map { JSString($0) })
    let shared = changeSetRefs(older).filter { refs.contains(JSString($0)) }
    return !shared.isEmpty && !PassageAnchoring.rewritesApart(older: older, newer: newer, shared: shared, drafts: drafts)
  }

  /// proposal.service.ts:84, :216: the session's own pending cards, judged by the decision each one holds in this transaction, which is the source of truth;
  /// a card this device cannot read is left to the apply-time baseline check, as another session's are.
  static func pendingCards(novel: UUID, session: UUID, in transaction: borrowing WriteTransaction) throws(StoreError) -> [ProposalRecord] {
    var cards = [ProposalRecord]()
    for ref in try candidates(novel: novel, session: session, in: transaction) {
      guard case .readable(let entry) = try ProposalRecord.read(ref, in: transaction) else { continue }
      let card = entry.record.card
      guard entry.record.decision == .known(.pending), card.novel == novel, card.session == session,
        let kind = card.kind.known, chatStagedKinds.contains(kind)
      else { continue }
      cards.append(entry.record)
    }
    return cards
  }

  /// The cards that may be the session's pending ones: the chat derivation's pending rows for the session, the proposals whose rows that derivation holds
  /// faulted, and those written earlier in this transaction, which the derivation, reconciled at commit, does not hold yet. Without the derivation, or with
  /// it faulted whole, every proposal of the vault is a candidate.
  private static func candidates(novel: UUID, session: UUID, in transaction: borrowing WriteTransaction) throws(StoreError) -> [EntityRef] {
    let index: Index?
    do {
      index = try indexed(novel: novel, session: session, in: transaction.database)
    } catch let error as StoreError {
      throw error
    } catch {
      throw StoreError(projecting: error)
    }
    let written = transaction.changes.filter { $0.entity == NovelForgeKind.proposal.entityKind }.map { EntityRef(kind: $0.entity, key: $0.key) }
    var refs = written
    switch index {
    case nil:
      refs += try transaction.states(ofKind: NovelForgeKind.proposal.entityKind, scope: .vault).map(\.ref)
    case .some(let index):
      refs += index.pending.map(NovelForgeKey.proposal)
      if !index.faulted.isEmpty {
        refs += try transaction.states(ofKind: NovelForgeKind.proposal.entityKind, scope: .vault).map(\.ref).filter { index.faulted.contains(ProjectionFaults.key($0)) }
      }
    }
    var seen = Set<EntityRef>()
    return refs.filter { seen.insert($0).inserted }
  }

  private struct Index {
    let pending: [UUID]
    let faulted: Set<String>
  }

  // The decision only rises, so a card the derivation does not hold pending at the transaction's start cannot be pending now.
  private static func indexed(novel: UUID, session: UUID, in database: Database) throws -> Index? {
    guard try database.tableExists(ProposalState.databaseTableName) else { return nil }
    var faulted = Set<String>()
    if try database.tableExists(ProjectionFaults.table) {
      faulted = Set(
        try String.fetchAll(database, sql: "SELECT key FROM \(ProjectionFaults.table) WHERE derivation = ?", arguments: [ProposalState.databaseTableName]))
      if faulted.contains(ProjectionFaults.wholeDerivation) { return nil }
    }
    let pending = Column("novel") == novel && Column("session") == session && Column("decision") == ProposalDecision.pending.rawValue
    return Index(pending: try ProposalState.select(Column("proposal"), as: UUID.self).filter(pending).order(Column("proposal")).fetchAll(database), faulted: faulted)
  }
}
