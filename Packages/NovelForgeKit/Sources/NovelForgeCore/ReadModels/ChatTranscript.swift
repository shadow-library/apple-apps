import Foundation
import GRDB
import ShadowCore
import ShadowStore

public struct ChatTranscriptQuery: Sendable, Equatable {
  public let session: UUID
  /// Only messages before this position, for paging back; nil reads from the newest.
  public let before: Int?
  public let limit: Int

  public init(session: UUID, before: Int? = nil, limit: Int = ChatTranscript.pageSize) {
    self.session = session
    self.before = before
    self.limit = limit
  }
}

public struct ChatTranscriptMessage: Sendable, Equatable {
  public let position: Int
  public let isCovered: Bool
  public let row: ChatMessageRow
  public let record: ChatMessageRecord?
}

public struct ChatTranscriptPage: Sendable, Equatable {
  public let messages: [ChatTranscriptMessage]
  public let total: Int

  public var hasEarlier: Bool { (messages.first?.position ?? 1) > 1 }
}

/// apps/novel-forge-server/src/modules/refinement/chat-session.service.ts:116-129: the latest `limit` messages before a position, returned oldest first.
public struct ChatTranscript: ReadModel {
  public static let pageSize = 50

  public let state: Derived<ChatSessionState?>
  public let page: Derived<ChatTranscriptPage>
  public let faults: [ReadFault]

  static let tables = [ChatSessionState.databaseTableName, ChatTranscriptRow.databaseTableName]

  public static func load(_ query: ChatTranscriptQuery, in transaction: ReadTransaction) throws(StoreError) -> ChatTranscript {
    let report = try ChatReadFaults(novel: nil, subject: NovelForgeKey.chatSession(query.session), reading: tables, in: transaction)
    return ChatTranscript(
      state: try report.section(tables) { () throws(StoreError) in try state(of: query.session, in: transaction) },
      page: try report.section(tables) { () throws(StoreError) in
        let total = try transaction.query { database in try ChatTranscriptRow.filter(Column("session") == query.session).fetchCount(database) }
        let messages = try ChatTranscript.messages(of: query.session, before: query.before, newest: max(query.limit, 0), in: transaction)
        return ChatTranscriptPage(messages: messages, total: total)
      },
      faults: report.relevant)
  }

  static func state(of session: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChatSessionState? {
    try transaction.query { database in try ChatSessionState.filter(Column("session") == session).fetchOne(database) }
  }

  static func messages(of session: UUID, before: Int? = nil, uncoveredOnly: Bool = false, newest limit: Int? = nil, in transaction: ReadTransaction)
    throws(StoreError) -> [ChatTranscriptMessage]
  {
    var sql = """
      SELECT t.position AS position, t.covered AS covered, m.* FROM \(ChatTranscriptRow.databaseTableName) t
      JOIN \(ChatMessageRow.databaseTableName) m ON m.key = t.message WHERE t.session = ?
      """
    var arguments: StatementArguments = [session]
    if let before {
      sql += " AND t.position < ?"
      arguments += [before]
    }
    if uncoveredOnly { sql += " AND t.covered = 0" }
    sql += " ORDER BY t.position DESC"
    if let limit {
      sql += " LIMIT ?"
      arguments += [limit]
    }
    let (query, values) = (sql, arguments)
    let rows = try transaction.query { database in
      try Row.fetchAll(database, sql: query, arguments: values).map { row in
        (position: row["position"] as Int, covered: row["covered"] as Bool, message: try ChatMessageRow(row: row))
      }
    }
    var messages = [ChatTranscriptMessage]()
    for entry in rows.reversed() {
      let record = entry.message.isReadable ? try ChatMessageRecord.read(entry.message.ref, in: transaction).entry?.record : nil
      messages.append(ChatTranscriptMessage(position: entry.position, isCovered: entry.covered, row: entry.message, record: record))
    }
    return messages
  }
}

public struct ChatWindowContents: Sendable, Equatable {
  public let summary: AppendedEntry<ChatSummaryRecord>?
  /// Every message the summary does not cover, oldest first, whenever it arrived.
  public let messages: [ChatTranscriptMessage]
}

/// The conversation a turn and compaction read (chat-compaction.service.ts:90-110 and :198-203): the standing summary and the messages it leaves out.
public struct ChatWindow: ReadModel {
  public let window: Derived<ChatWindowContents?>
  public let lock: Derived<ChatUnrestrictedLock?>
  public let faults: [ReadFault]

  public static func load(_ session: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChatWindow {
    let tables = ChatTranscript.tables
    let report = try ChatReadFaults(novel: nil, subject: NovelForgeKey.chatSession(session), reading: tables, in: transaction)
    let window = try report.section(tables) { () throws(StoreError) -> ChatWindowContents? in
      guard let state = try ChatTranscript.state(of: session, in: transaction) else { return nil }
      let summary = try state.summary.flatMap { key throws(StoreError) in
        try ChatSummaryRecord.read(EntityRef(kind: NovelForgeKind.chatSummary.entityKind, key: key), in: transaction).entry
      }
      let messages = try ChatTranscript.messages(of: session, uncoveredOnly: true, in: transaction)
      return ChatWindowContents(summary: summary, messages: messages)
    }
    let blocking = ChatUnrestrictedLock.faults(among: report.relevant)
    let lock =
      blocking.isEmpty
      ? try report.section(tables) { () throws(StoreError) in try ChatTranscript.state(of: session, in: transaction)?.lock } : .unavailable(blocking)
    return ChatWindow(window: window, lock: lock, faults: report.relevant)
  }
}
