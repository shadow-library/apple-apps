import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// One compaction summary as its session reads it: how many message ids it covers decides which summary stands.
public struct ChatSummaryRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_chat_summary"

  public let key: EntityKey
  public let novel: UUID
  public let session: UUID
  public let clock: HLCTimestamp
  public let isReadable: Bool
  public let contentMode: StoredEnum<ContentMode>?
  public let covered: Int

  init(key: EntityKey, novel: UUID, session: UUID, clock: HLCTimestamp, isReadable: Bool, contentMode: StoredEnum<ContentMode>?, covered: Int) {
    self.key = key
    self.novel = novel
    self.session = session
    self.clock = clock
    self.isReadable = isReadable
    self.contentMode = contentMode
    self.covered = covered
  }

  public init(row: Row) throws {
    self.init(
      key: try ChatColumns.key(row, "key"), novel: try row.decode(UUID.self, forColumn: "novel"), session: try row.decode(UUID.self, forColumn: "session"),
      clock: try ChatColumns.clock(row, "clock"), isReadable: try row.decode(Bool.self, forColumn: "readable"),
      contentMode: try ChatColumns.stored(row, "content_mode"), covered: try row.decode(Int.self, forColumn: "covered"))
  }

  public var ref: EntityRef { EntityRef(kind: NovelForgeKind.chatSummary.entityKind, key: key) }

  /// A summary always records its mode, so one that cannot show it was standard counts as unrestricted.
  public var claimsUnrestricted: Bool { contentMode != .known(.standard) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["key"] = key.rawValue
    container["novel"] = novel
    container["session"] = session
    container["clock"] = clock.description
    container["readable"] = isReadable
    container["content_mode"] = contentMode?.rawValue
    container["covered"] = covered
  }
}

public struct ChatSummaryRowDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_chat_summary (
      key TEXT PRIMARY KEY, novel BLOB NOT NULL, session BLOB NOT NULL, clock TEXT NOT NULL, readable INTEGER NOT NULL, content_mode TEXT, covered INTEGER NOT NULL
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_chat_summary_session ON nf_derived_chat_summary (session);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.records([.chatSummary]) { [$0] }]
  }

  public static func key(of output: ChatSummaryRow) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<ChatSummaryRow> {
    ChatSummaryRow.filter(Column("key") == ref.key.rawValue)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .chatSummary))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ChatSummaryRow] {
    let state = try context.records.state(of: ref, scope: .vault)
    switch ChatSummaryRecord.reading(state, of: ref) {
    case .absent:
      return []
    case .readable(let entry):
      let summary = entry.record
      return [
        ChatSummaryRow(
          key: ref.key, novel: summary.novel, session: summary.session, clock: entry.clock, isReadable: true, contentMode: summary.contentMode,
          covered: Set(summary.covered).count)
      ]
    case .unreadable:
      guard case .appended(let appended)? = state, let item = ChatRawItem(appended.item) else { return [] }
      return [
        ChatSummaryRow(
          key: ref.key, novel: item.novel, session: item.session, clock: appended.clock, isReadable: false,
          contentMode: ChatColumns.stored(item.members[ChatSummaryMember.contentMode.rawValue]), covered: 0)
      ]
    }
  }
}
