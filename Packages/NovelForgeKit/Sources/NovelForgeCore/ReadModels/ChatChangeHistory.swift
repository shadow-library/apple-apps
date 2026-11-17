import Foundation
import GRDB
import ShadowCore
import ShadowStore

public struct ChatChangeHistoryQuery: Sendable, Equatable {
  public let novel: UUID
  public let offset: Int
  public let limit: Int

  // apps/novel-forge-server/src/modules/refinement/proposal.service.ts:262 pages 30 at a time
  public init(novel: UUID, offset: Int = 0, limit: Int = 30) {
    self.novel = novel
    self.offset = offset
    self.limit = limit
  }
}

/// One index of an applied card as the history reads it.
public struct ChatChangeEntry: Sendable, Equatable {
  public let row: ProposalEntryRow
  /// The rewrite whose step applied this one (`CarriedRewrites`): it holds no undo of its own and stands as its leader does.
  public let carriedBy: Int?
  /// The leader's state for a carried rewrite, the row's own otherwise.
  public let state: ProposalChangeEntryState
  /// Whether the change, or the leader that carries it, holds an undo.
  public let hasUndo: Bool

  public var index: Int { row.index }
  public var isAction: Bool { row.isAction }
}

public struct ChatChange: Sendable, Equatable {
  public let applied: HLCTimestamp
  public let state: ProposalState
  public let session: ChatProposalSession
  /// nil when this device cannot read the proposal; it is listed all the same, its entries as recorded.
  public let record: ProposalRecord?
  /// One per index of the card: an unreadable or unrecognised change shows as such, never left out, since it may hold an undo.
  public let entries: [ChatChangeEntry]

  init(applied: HLCTimestamp, state: ProposalState, session: ChatProposalSession, record: ProposalRecord?, rows: [ProposalEntryRow]) {
    self.applied = applied
    self.state = state
    self.session = session
    self.record = record
    let leaders = record.map { CarriedRewrites.leaders(of: $0.card.changeSet, selected: $0.application?.selected ?? []) } ?? [:]
    let byIndex = Dictionary(rows.map { ($0.index, $0) }) { first, _ in first }
    entries = rows.map { row in
      guard let leader = leaders[row.index].flatMap({ byIndex[$0] }), !row.isAction, row.state == .applied, !row.hasUndo else {
        return ChatChangeEntry(row: row, carriedBy: nil, state: row.state, hasUndo: row.hasUndo)
      }
      return ChatChangeEntry(row: row, carriedBy: leader.index, state: leader.state, hasUndo: leader.hasUndo)
    }
  }

  /// changeSetRefs over the ops this version reads (proposal.service.ts:296).
  public var refs: [String] { changeSetRefs(record?.card.changeSet.compactMap(\.op) ?? []) }

  /// proposal.service.ts:297 (status applied with inverse ops): a content change stands applied and holds its undo.
  public var isRevertible: Bool { entries.contains { !$0.isAction && $0.state == .applied && $0.hasUndo } }

  /// The reference's `reverted` status: every content change was reverted and none stands applied, awaiting or unknown.
  public var isReverted: Bool {
    let content = entries.filter { !$0.isAction }
    return content.contains { $0.state == .reverted } && !content.contains { [.applied, .awaiting, .unreadable, .unrecognised].contains($0.state) }
  }
}

public struct ChatChangePage: Sendable, Equatable {
  public let changes: [ChatChange]
  public let total: Int
}

/// proposal.service.ts:258-306: the novel's applied proposals, newest apply first, whatever chat they came from, a deleted one included.
public struct ChatChangeHistory: ReadModel {
  public let page: Derived<ChatChangePage>
  public let faults: [ReadFault]

  private static let tables = [ProposalHistoryRow.databaseTableName, ProposalState.databaseTableName, ProposalEntryRow.databaseTableName]

  public static func load(_ query: ChatChangeHistoryQuery, in transaction: ReadTransaction) throws(StoreError) -> ChatChangeHistory {
    let report = try ReadFaults(novel: query.novel, reading: tables, in: transaction)
    let page = try report.section(tables) { () throws(StoreError) -> ChatChangePage in
      let rows = try transaction.query { database in try ProposalHistoryRow.filter(Column("novel") == query.novel).fetchAll(database) }
      let sessions = try ChatSessionStandings(novel: query.novel, in: transaction)
      let newestFirst = rows.sorted { $0.applied == $1.applied ? $0.ref > $1.ref : $0.applied > $1.applied }
      var changes = [ChatChange]()
      for row in newestFirst.dropFirst(max(query.offset, 0)).prefix(max(query.limit, 0)) {
        guard let change = try change(row, sessions: sessions, in: transaction) else { continue }
        changes.append(change)
      }
      return ChatChangePage(changes: changes, total: rows.count)
    }
    return ChatChangeHistory(page: page, faults: report.relevant)
  }

  private static func change(_ row: ProposalHistoryRow, sessions: ChatSessionStandings, in transaction: ReadTransaction) throws(StoreError) -> ChatChange? {
    let (state, entries) = try transaction.query { database in
      (
        try ProposalState.filter(Column("proposal") == row.proposal).fetchOne(database),
        try ProposalEntryRow.filter(Column("proposal") == row.proposal).order(Column("op")).fetchAll(database)
      )
    }
    guard let state else { return nil }
    let record = try ProposalRecord.read(id: row.proposal, in: transaction).entry?.record
    return ChatChange(applied: row.applied, state: state, session: sessions.standing(of: state.session), record: record, rows: entries)
  }
}
