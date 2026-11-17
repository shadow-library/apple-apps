import Foundation
import GRDB
import ShadowCore
import ShadowStore

public enum ChatSessionRecordState: String, Sendable, DatabaseValueConvertible {
  case live
  case removed
  case unreadable
  /// Its messages arrived before the session record, or a newer version wrote them under an id this vault holds no record for.
  case absent
}

/// The first item of a session that may hold unrestricted text. Items are only ever appended, so the lock lifts only if the locking item is purged; no
/// domain operation purges chat items, and a session is deleted by removal, never by purge.
public struct ChatUnrestrictedLock: Hashable, Sendable {
  public let item: EntityRef
  public let clock: HLCTimestamp
}

public struct ChatSessionState: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_chat_session"

  public let session: UUID
  public let novel: UUID
  public let record: ChatSessionRecordState
  public let messages: Int
  /// Messages that cannot be shown: unreadable ones, and those naming this session under another novel, which the transcript leaves out.
  public let unreadableMessages: Int
  /// apps/novel-forge-server/src/modules/refinement/chat-session.service.ts:80 (`started`): it holds a readable author message.
  public let isStarted: Bool
  public let latest: EntityKey?
  public let latestClock: HLCTimestamp?
  /// The newest clock among the session record's fields and its items, which orders the session list as the reference's `updatedAt` does.
  public let updated: HLCTimestamp?
  /// The summary that stands: the readable one of this novel covering the most messages, then the newest.
  public let summary: EntityKey?
  public let unreadableSummaries: Int
  public let lock: ChatUnrestrictedLock?

  init(
    session: UUID, novel: UUID, record: ChatSessionRecordState, messages: Int, unreadableMessages: Int, isStarted: Bool, latest: EntityKey?, latestClock: HLCTimestamp?,
    updated: HLCTimestamp?, summary: EntityKey?, unreadableSummaries: Int, lock: ChatUnrestrictedLock?
  ) {
    self.session = session
    self.novel = novel
    self.record = record
    self.messages = messages
    self.unreadableMessages = unreadableMessages
    self.isStarted = isStarted
    self.latest = latest
    self.latestClock = latestClock
    self.updated = updated
    self.summary = summary
    self.unreadableSummaries = unreadableSummaries
    self.lock = lock
  }

  public init(row: Row) throws {
    var lock: ChatUnrestrictedLock?
    if let kind = try row.decode(String?.self, forColumn: "locked_kind") {
      guard let kind = EntityKind(kind), let key = try ChatColumns.optionalKey(row, "locked_key"), let clock = try ChatColumns.optionalClock(row, "locked_clock") else {
        throw StoreError.corruptStore("a chat session row holds an incomplete lock")
      }
      lock = ChatUnrestrictedLock(item: EntityRef(kind: kind, key: key), clock: clock)
    }
    self.init(
      session: try row.decode(UUID.self, forColumn: "session"), novel: try row.decode(UUID.self, forColumn: "novel"),
      record: try row.decode(ChatSessionRecordState.self, forColumn: "record"), messages: try row.decode(Int.self, forColumn: "messages"),
      unreadableMessages: try row.decode(Int.self, forColumn: "unreadable_messages"), isStarted: try row.decode(Bool.self, forColumn: "started"),
      latest: try ChatColumns.optionalKey(row, "latest"), latestClock: try ChatColumns.optionalClock(row, "latest_clock"),
      updated: try ChatColumns.optionalClock(row, "updated"), summary: try ChatColumns.optionalKey(row, "summary"),
      unreadableSummaries: try row.decode(Int.self, forColumn: "unreadable_summaries"), lock: lock)
  }

  public var ref: EntityRef { NovelForgeKey.chatSession(session) }

  public var isLocked: Bool { lock != nil }

  public func encode(to container: inout PersistenceContainer) throws {
    container["session"] = session
    container["novel"] = novel
    container["record"] = record
    container["messages"] = messages
    container["unreadable_messages"] = unreadableMessages
    container["started"] = isStarted
    container["latest"] = latest?.rawValue
    container["latest_clock"] = latestClock?.description
    container["updated"] = updated?.description
    container["summary"] = summary?.rawValue
    container["unreadable_summaries"] = unreadableSummaries
    container["locked_kind"] = lock?.item.kind.rawValue
    container["locked_key"] = lock?.item.key.rawValue
    container["locked_clock"] = lock?.clock.description
  }
}

// apps/novel-forge-server/src/modules/refinement/chat-compaction.service.ts:114-142 raises every later fold of a session to unrestricted once it holds
// unrestricted text, and a standard turn then reads placeholders; here the lock is the earliest such item.
public struct ChatSessionStateDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_chat_session (
      session BLOB PRIMARY KEY, novel BLOB NOT NULL, record TEXT NOT NULL, messages INTEGER NOT NULL, unreadable_messages INTEGER NOT NULL, started INTEGER NOT NULL,
      latest TEXT, latest_clock TEXT, updated TEXT, summary TEXT, unreadable_summaries INTEGER NOT NULL, locked_kind TEXT, locked_key TEXT, locked_clock TEXT
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_chat_session_novel ON nf_derived_chat_session (novel);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [
      .records([.chatSession]) { [$0] },
      .outputs(of: ChatMessageRowDerivation.self) { [NovelForgeKey.chatSession($0.session)] },
      .outputs(of: ChatSummaryRowDerivation.self) { [NovelForgeKey.chatSession($0.session)] },
    ]
  }

  public static func key(of output: ChatSessionState) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<ChatSessionState> {
    guard let session = ChatColumns.id(of: ref, .chatSession) else { return ChatSessionState.filter(sql: "0") }
    return ChatSessionState.filter(Column("session") == session)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    var refs = Set(try context.refs(of: .chatSession))
    let sessions = try context.read { database in
      try UUID.fetchAll(
        database, sql: "SELECT session FROM \(ChatMessageRow.databaseTableName) UNION SELECT session FROM \(ChatSummaryRow.databaseTableName)")
    }
    refs.formUnion(sessions.map(NovelForgeKey.chatSession))
    return refs
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ChatSessionState] {
    guard let session = ChatColumns.id(of: ref, .chatSession) else { return [] }
    let state = try context.records.state(of: ref, scope: .vault)
    let (record, recordNovel) = Self.record(ref, state)
    let messages = try context.fetchAll(ChatMessageRow.filter(Column("session") == session))
    let summaries = try context.fetchAll(ChatSummaryRow.filter(Column("session") == session))
    let items = messages.map { (clock: $0.clock, ref: $0.ref, novel: $0.novel) } + summaries.map { (clock: $0.clock, ref: $0.ref, novel: $0.novel) }
    guard let novel = recordNovel ?? items.min(by: { ChatColumns.precedes(($0.clock, $0.ref), ($1.clock, $1.ref)) })?.novel else { return [] }

    let transcript = messages.filter { $0.novel == novel }
    let latest = transcript.max { ChatColumns.precedes(($0.clock, $0.ref), ($1.clock, $1.ref)) }
    let standing = summaries.filter { $0.isReadable && $0.novel == novel }.max { first, second in
      guard first.covered == second.covered else { return first.covered < second.covered }
      return ChatColumns.precedes((first.clock, first.ref), (second.clock, second.ref))
    }
    let claims = messages.filter(\.claimsUnrestricted).map { (clock: $0.clock, ref: $0.ref) } + summaries.filter(\.claimsUnrestricted).map { (clock: $0.clock, ref: $0.ref) }
    let lock = claims.min(by: ChatColumns.precedes).map { ChatUnrestrictedLock(item: $0.ref, clock: $0.clock) }
    var clocks = items.map(\.clock)
    if case .record(let stored)? = state { clocks.append(contentsOf: stored.fields.values.map(\.clock)) }

    return [
      ChatSessionState(
        session: session, novel: novel, record: record, messages: transcript.count,
        unreadableMessages: transcript.count { !$0.isReadable } + messages.count - transcript.count,
        isStarted: transcript.contains { $0.isReadable && $0.role == .known(.user) }, latest: latest?.key, latestClock: latest?.clock, updated: clocks.max(),
        summary: standing?.key, unreadableSummaries: summaries.count { !$0.isReadable || $0.novel != novel }, lock: lock)
    ]
  }

  private static func record(_ ref: EntityRef, _ state: EntityState?) -> (ChatSessionRecordState, UUID?) {
    switch ChatSessionRecord.reading(state, of: ref) {
    case .absent:
      return (.absent, nil)
    case .readable(let entry):
      return (entry.isRemoved ? .removed : .live, entry.record.novel)
    case .unreadable:
      guard case .record(let stored)? = state else { return (.unreadable, nil) }
      return (.unreadable, stored[field: ChatSessionField.novel.rawValue].flatMap { UUID(json: $0.value) })
    }
  }
}
