import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// One chat message as its session reads it; an unreadable message still names its session and novel when its raw item does, so the transcript shows it
/// as a message that could not be read instead of leaving a gap.
public struct ChatMessageRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_chat_message"

  public let key: EntityKey
  public let novel: UUID
  public let session: UUID
  public let clock: HLCTimestamp
  public let isReadable: Bool
  public let role: StoredEnum<ChatRole>?
  public let contentMode: StoredEnum<ContentMode>?
  public let answers: UUID?
  public let seen: UUID?
  public let cardProposal: UUID?
  public let appliedProposal: UUID?
  public let hasUnreadableContexts: Bool
  public let hasUnreadableQuestion: Bool

  init(
    key: EntityKey, novel: UUID, session: UUID, clock: HLCTimestamp, isReadable: Bool, role: StoredEnum<ChatRole>?, contentMode: StoredEnum<ContentMode>?,
    answers: UUID? = nil, seen: UUID? = nil, cardProposal: UUID? = nil, appliedProposal: UUID? = nil, hasUnreadableContexts: Bool = false,
    hasUnreadableQuestion: Bool = false
  ) {
    self.key = key
    self.novel = novel
    self.session = session
    self.clock = clock
    self.isReadable = isReadable
    self.role = role
    self.contentMode = contentMode
    self.answers = answers
    self.seen = seen
    self.cardProposal = cardProposal
    self.appliedProposal = appliedProposal
    self.hasUnreadableContexts = hasUnreadableContexts
    self.hasUnreadableQuestion = hasUnreadableQuestion
  }

  public init(row: Row) throws {
    self.init(
      key: try ChatColumns.key(row, "key"), novel: try row.decode(UUID.self, forColumn: "novel"), session: try row.decode(UUID.self, forColumn: "session"),
      clock: try ChatColumns.clock(row, "clock"), isReadable: try row.decode(Bool.self, forColumn: "readable"), role: try ChatColumns.stored(row, "role"),
      contentMode: try ChatColumns.stored(row, "content_mode"), answers: try row.decode(UUID?.self, forColumn: "answers"),
      seen: try row.decode(UUID?.self, forColumn: "seen"), cardProposal: try row.decode(UUID?.self, forColumn: "card_proposal"),
      appliedProposal: try row.decode(UUID?.self, forColumn: "applied_proposal"),
      hasUnreadableContexts: try row.decode(Bool.self, forColumn: "unreadable_contexts"),
      hasUnreadableQuestion: try row.decode(Bool.self, forColumn: "unreadable_question"))
  }

  public var ref: EntityRef { EntityRef(kind: NovelForgeKind.chatMessage.entityKind, key: key) }

  public var id: UUID? { ChatColumns.id(of: ref, .chatMessage) }

  /// An unknown mode counts, and so does a modeless message not known to be the author's: the reference runs a reply with no recorded selection in the
  /// novel's mode, which may be unrestricted (apps/novel-forge-server/src/modules/refinement/chat-compaction.service.ts:181-186).
  public var claimsUnrestricted: Bool {
    guard let contentMode else { return role != .known(.user) }
    return contentMode != .known(.standard)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["key"] = key.rawValue
    container["novel"] = novel
    container["session"] = session
    container["clock"] = clock.description
    container["readable"] = isReadable
    container["role"] = role?.rawValue
    container["content_mode"] = contentMode?.rawValue
    container["answers"] = answers
    container["seen"] = seen
    container["card_proposal"] = cardProposal
    container["applied_proposal"] = appliedProposal
    container["unreadable_contexts"] = hasUnreadableContexts
    container["unreadable_question"] = hasUnreadableQuestion
  }
}

public struct ChatMessageRowDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_chat_message (
      key TEXT PRIMARY KEY, novel BLOB NOT NULL, session BLOB NOT NULL, clock TEXT NOT NULL, readable INTEGER NOT NULL, role TEXT, content_mode TEXT,
      answers BLOB, seen BLOB, card_proposal BLOB, applied_proposal BLOB, unreadable_contexts INTEGER NOT NULL, unreadable_question INTEGER NOT NULL
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_chat_message_session ON nf_derived_chat_message (session);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.records([.chatMessage]) { [$0] }]
  }

  public static func key(of output: ChatMessageRow) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<ChatMessageRow> {
    ChatMessageRow.filter(Column("key") == ref.key.rawValue)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .chatMessage))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ChatMessageRow] {
    let state = try context.records.state(of: ref, scope: .vault)
    switch ChatMessageRecord.reading(state, of: ref) {
    case .absent:
      return []
    case .readable(let entry):
      let message = entry.record
      return [
        ChatMessageRow(
          key: ref.key, novel: message.novel, session: message.session, clock: entry.clock, isReadable: true, role: message.role, contentMode: message.contentMode,
          answers: message.answers, seen: message.seen, cardProposal: message.cardProposal, appliedProposal: message.appliedProposal,
          hasUnreadableContexts: message.hasUnreadableContexts, hasUnreadableQuestion: message.hasUnreadableQuestion)
      ]
    case .unreadable:
      guard case .appended(let appended)? = state, let item = ChatRawItem(appended.item) else { return [] }
      return [
        ChatMessageRow(
          key: ref.key, novel: item.novel, session: item.session, clock: appended.clock, isReadable: false, role: ChatColumns.stored(item.members[ChatMessageMember.role.rawValue]),
          contentMode: ChatColumns.stored(item.members[ChatMessageMember.contentMode.rawValue]))
      ]
    }
  }
}

/// The novel and session an appended chat item names, read without decoding the rest of it.
struct ChatRawItem {
  let members: [String: JSONValue]
  let novel: UUID
  let session: UUID

  init?(_ members: [String: JSONValue]) {
    guard let novel = members["novel"].flatMap(UUID.init(json:)), let session = members["session"].flatMap(UUID.init(json:)) else { return nil }
    self.members = members
    self.novel = novel
    self.session = session
  }
}
