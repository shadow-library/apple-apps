import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// A message's place in its session: 1-based, by clock then ref, and whether the summary that stands covers it.
public struct ChatTranscriptRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_chat_transcript"

  public let session: UUID
  public let position: Int
  public let message: EntityKey
  public let clock: HLCTimestamp
  public let isCovered: Bool

  init(session: UUID, position: Int, message: EntityKey, clock: HLCTimestamp, isCovered: Bool) {
    self.session = session
    self.position = position
    self.message = message
    self.clock = clock
    self.isCovered = isCovered
  }

  public init(row: Row) throws {
    self.init(
      session: try row.decode(UUID.self, forColumn: "session"), position: try row.decode(Int.self, forColumn: "position"),
      message: try ChatColumns.key(row, "message"), clock: try ChatColumns.clock(row, "clock"), isCovered: try row.decode(Bool.self, forColumn: "covered"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["session"] = session
    container["position"] = position
    container["message"] = message.rawValue
    container["clock"] = clock.description
    container["covered"] = isCovered
  }
}

// apps/novel-forge-server/src/modules/refinement/chat-session.service.ts:116-129 pages by a dense ordinal and chat-compaction.service.ts:198-203 reads the
// window after the summary's watermark; here the order is the clock then the ref, and the window is every message the standing summary does not list,
// whenever it arrives.
public struct ChatTranscriptDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_chat_transcript (
      session BLOB NOT NULL, position INTEGER NOT NULL, message TEXT NOT NULL, clock TEXT NOT NULL, covered INTEGER NOT NULL, PRIMARY KEY (session, position)
    ) STRICT, WITHOUT ROWID;
    CREATE UNIQUE INDEX nf_derived_chat_transcript_message ON nf_derived_chat_transcript (session, message);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [
      .outputs(of: ChatMessageRowDerivation.self) { [NovelForgeKey.chatSession($0.session)] },
      .outputs(of: ChatSessionStateDerivation.self) { [$0.ref] },
    ]
  }

  public static func key(of output: ChatTranscriptRow) -> EntityRef { NovelForgeKey.chatSession(output.session) }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<ChatTranscriptRow> {
    guard let session = ChatColumns.id(of: ref, .chatSession) else { return ChatTranscriptRow.filter(sql: "0") }
    return ChatTranscriptRow.filter(Column("session") == session)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.fetchAll(ChatSessionState.all()).map(\.ref))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ChatTranscriptRow] {
    guard let session = ChatColumns.id(of: ref, .chatSession), let state = try context.fetchAll(ChatSessionState.filter(Column("session") == session)).first else {
      return []
    }
    var covered = Set<UUID>()
    if let summary = state.summary, let entry = try ChatSummaryRecord.read(EntityRef(kind: NovelForgeKind.chatSummary.entityKind, key: summary), in: context.records).entry {
      covered = Set(entry.record.covered)
    }
    let messages = try context.fetchAll(ChatMessageRow.filter(Column("session") == session && Column("novel") == state.novel))
    return messages.sorted { ChatColumns.precedes(($0.clock, $0.ref), ($1.clock, $1.ref)) }.enumerated().map { offset, row in
      ChatTranscriptRow(session: session, position: offset + 1, message: row.key, clock: row.clock, isCovered: row.id.map(covered.contains) ?? false)
    }
  }
}
