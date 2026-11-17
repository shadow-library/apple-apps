import Foundation
import ShadowStore

public enum ChatSessionFilter: Sendable, Equatable {
  /// Every chat not archived; a chat whose record this version cannot read, or has not received yet, is listed here rather than hidden.
  case active
  case archived
  case all
}

public struct ChatSessionListQuery: Sendable, Equatable {
  public let novel: UUID
  public let filter: ChatSessionFilter
  /// Only chats the author has posted in (chat.dto.ts:63-64).
  public let startedOnly: Bool

  public init(novel: UUID, filter: ChatSessionFilter = .active, startedOnly: Bool = false) {
    self.novel = novel
    self.filter = filter
    self.startedOnly = startedOnly
  }
}

/// chat-session.service.ts:73-94: the novel's chats, most recently updated first, by status and, if asked, only those the author posted in. Deleted chats are
/// never listed. The whole list is read: a novel holds tens of chats and its rows are derived and indexed by novel, so the reference's paging is not kept.
public struct ChatSessionList: ReadModel {
  public let sessions: Derived<[ChatSessionOverview]>
  public let faults: [ReadFault]

  public static func load(_ query: ChatSessionListQuery, in transaction: ReadTransaction) throws(StoreError) -> ChatSessionList {
    let all = try ChatSessions.load(query.novel, in: transaction)
    let sessions = all.sessions.map { sessions in
      sessions.filter { overview in
        guard overview.state.record != .removed, !query.startedOnly || overview.state.isStarted else { return false }
        let archived = overview.record?.status == .known(.archived)
        switch query.filter {
        case .active: return !archived
        case .archived: return archived
        case .all: return true
        }
      }
    }
    return ChatSessionList(sessions: sessions, faults: all.faults)
  }
}
