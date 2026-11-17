import Foundation
import GRDB
import ShadowCore
import ShadowStore

public struct ChatSessionOverview: Sendable, Equatable {
  public let state: ChatSessionState
  public let record: ChatSessionRecord?
}

/// Every chat of a novel, removed ones included, most recently updated first (chat-session.service.ts:73-94 sorts by `updatedAt` descending).
public struct ChatSessions: ReadModel {
  public let sessions: Derived<[ChatSessionOverview]>
  public let faults: [ReadFault]

  private static let tables = [ChatSessionState.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChatSessions {
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    let sessions = try report.section(tables) { () throws(StoreError) -> [ChatSessionOverview] in
      let states = try transaction.query { database in try ChatSessionState.filter(Column("novel") == novel).fetchAll(database) }
      var sessions = [ChatSessionOverview]()
      for state in states.sorted(by: newestFirst) {
        sessions.append(ChatSessionOverview(state: state, record: try ChatSessionRecord.read(state.ref, in: transaction).entry?.record))
      }
      return sessions
    }
    return ChatSessions(sessions: sessions, faults: report.relevant)
  }

  /// Whether any chat of the novel, a removed one included, may hold unrestricted text.
  public var holdsUnrestrictedText: Derived<Bool> {
    let blocking = ChatUnrestrictedLock.faults(among: faults)
    guard blocking.isEmpty else { return .unavailable(blocking) }
    return sessions.map { sessions in sessions.contains { $0.state.isLocked } }
  }

  private static func newestFirst(_ first: ChatSessionState, _ second: ChatSessionState) -> Bool {
    if first.updated != second.updated, let left = first.updated, let right = second.updated { return left > right }
    if (first.updated == nil) != (second.updated == nil) { return first.updated != nil }
    return first.ref < second.ref
  }
}

extension ChatUnrestrictedLock {
  private static let tables: Set<String> = [ChatSessionState.databaseTableName, ChatMessageRow.databaseTableName, ChatSummaryRow.databaseTableName]

  /// A faulted row is withdrawn and could take the locking item with it, so any fault on these tables makes a lock unknowable.
  static func faults(among faults: [ReadFault]) -> [ReadFault] {
    faults.filter { tables.contains($0.derivation) }
  }
}
