import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// What stops a card from applying as staged: the refs whose current state no longer matches its baseline, and the indexes that touch them.
public struct ChatCardConflict: Sendable, Equatable {
  public let refs: [String]
  public let indexes: [Int]
}

public struct ChatWaitingCard: Sendable, Equatable {
  public let state: ProposalState
  public let session: ChatProposalSession
  /// nil when this device cannot read the card: it still waits on the author and is shown as such.
  public let card: ProposalCard?
  public let conflict: ChatCardConflict?
}

public struct ChatPendingAction: Sendable, Equatable {
  public let proposal: UUID
  public let session: ChatProposalSession
  /// The card's actions recorded pending, in index order: applied, but not run yet or interrupted, so a resume runs them.
  public let indexes: [Int]
}

public struct ChatWaitingContents: Sendable, Equatable {
  /// Pending cards that would apply as staged, an unreadable one included, oldest staged first.
  public let cards: [ChatWaitingCard]
  /// Pending cards whose baseline no longer matches: the reference marks such a card conflicted (proposal-apply.service.ts:148-160) and stops waiting.
  public let conflicted: [ChatWaitingCard]
  public let actions: [ChatPendingAction]

  /// What waits on the author's decision (lib/pending-items.ts:164-180 lists pending cards only).
  public var pendingCount: Int { cards.count }
}

/// Everything about the novel's cards that waits on the author. `conflicted` is never stored: each readable pending card is planned as a whole apply against
/// the current records, as `ProposalApply` would before writing, so a card goes conflicted the moment something it was staged against changes, without an
/// apply attempt. Unsaved editor text is not read: an apply settles it first and may then conflict where this read did not. It covers cards and their actions
/// only: drafts to read, finalize decisions and continuity additions join it with the phases that bring them (lib/pending-items.ts:129-183).
public struct ChatWaitingOnYou: ReadModel {
  public let contents: Derived<ChatWaitingContents>
  public let faults: [ReadFault]

  private static let tables = [ProposalState.databaseTableName, ProposalEntryRow.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChatWaitingOnYou {
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    let contents = try report.section(tables) { () throws(StoreError) -> ChatWaitingContents in
      let pending = ProposalDecision.pending.rawValue
      let action = "e.action = 1 AND e.state = '\(ProposalChangeEntryState.pending.rawValue)'"
      let (states, entries) = try transaction.query { database in
        (
          try ProposalState.fetchAll(
            database,
            sql: """
              SELECT p.* FROM \(ProposalState.databaseTableName) p WHERE p.novel = ? AND (p.decision = ? OR (p.decision = ? AND EXISTS (
                SELECT 1 FROM \(ProposalEntryRow.databaseTableName) e WHERE e.proposal = p.proposal AND \(action))))
              """, arguments: [novel, pending, ProposalDecision.applied.rawValue]),
          try ProposalEntryRow.fetchAll(
            database,
            sql: """
              SELECT e.* FROM \(ProposalEntryRow.databaseTableName) e JOIN \(ProposalState.databaseTableName) p ON p.proposal = e.proposal
              WHERE p.novel = ? AND \(action)
              """, arguments: [novel])
        )
      }
      let ordered = states.sorted { $0.staged == $1.staged ? $0.ref < $1.ref : $0.staged < $1.staged }
      let sessions = try ChatSessionStandings(novel: novel, in: transaction)
      var cards = [ChatWaitingCard]()
      var conflicted = [ChatWaitingCard]()
      for state in ordered where state.isPending {
        let card = try readableCard(state, in: transaction)
        let conflict = try card.flatMap { card throws(StoreError) in try Self.conflict(of: card, novel: novel, in: transaction) }
        let waiting = ChatWaitingCard(state: state, session: sessions.standing(of: state.session), card: card, conflict: conflict)
        if conflict == nil { cards.append(waiting) } else { conflicted.append(waiting) }
      }
      let pendingIndexes = Dictionary(grouping: entries, by: \.proposal).mapValues { $0.map(\.index).sorted() }
      let actions = ordered.compactMap { state -> ChatPendingAction? in
        guard state.decision == .known(.applied), let indexes = pendingIndexes[state.proposal] else { return nil }
        return ChatPendingAction(proposal: state.proposal, session: sessions.standing(of: state.session), indexes: indexes)
      }
      return ChatWaitingContents(cards: cards, conflicted: conflicted, actions: actions)
    }
    return ChatWaitingOnYou(contents: contents, faults: report.relevant)
  }

  private static func readableCard(_ state: ProposalState, in transaction: ReadTransaction) throws(StoreError) -> ProposalCard? {
    guard state.readability != .cardUnreadable, case .readable(let entry) = try ProposalRecord.read(id: state.proposal, in: transaction) else { return nil }
    return entry.record.card
  }

  /// A plan that cannot be made for another reason than the store leaves the card waiting: the apply itself reports why.
  private static func conflict(of card: ProposalCard, novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChatCardConflict? {
    let plan: ApplyPlan
    do throws(ApplyError) {
      plan = try ApplyPlanner.plan(card.changeSet, baseline: card.baseline, selection: .whole, novel: novel, in: transaction)
    } catch {
      if case .store(let cause) = error { throw cause }
      return nil
    }
    guard case .conflicted(let mismatches) = plan else { return nil }
    return ChatCardConflict(refs: mismatches.map(\.ref), indexes: Array(Set(mismatches.flatMap(\.indexes))).sorted())
  }
}
