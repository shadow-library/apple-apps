import Foundation
import ShadowCore
import ShadowStore

extension ChatSessionField: FieldName {}

// apps/novel-forge-server/src/database/schemas/refinement.ts:157-187; the project scope, summary watermark and turn timestamps are derived from the messages and summaries
public struct ChatSessionRecord: NovelForgeRecord {
  public static let kind = NovelForgeKind.chatSession

  public let id: UUID
  public let novel: UUID
  public internal(set) var title: String?
  public internal(set) var autoTitle: String?
  public internal(set) var mode: StoredEnum<ChatSessionMode>
  public internal(set) var status: StoredEnum<ChatSessionStatus>

  // apps/novel-forge-server/src/modules/refinement/chat-session.service.ts:55 creates every session in `auto` mode
  public init(
    id: UUID = UUID(), novel: UUID, title: String? = nil, autoTitle: String? = nil, mode: ChatSessionMode = .auto, status: ChatSessionStatus = .active
  ) throws(ChatRecordError) {
    self.init(
      unvalidated: id, novel: novel, title: try title.map(validatedChatTitle),
      autoTitle: try autoTitle.map { text throws(ChatRecordError) in try validatedChatTitle(text.jsTrim()) },
      mode: .known(mode), status: .known(status))
  }

  init(unvalidated id: UUID, novel: UUID, title: String?, autoTitle: String?, mode: StoredEnum<ChatSessionMode>, status: StoredEnum<ChatSessionStatus>) {
    self.id = id
    self.novel = novel
    self.title = title
    self.autoTitle = autoTitle
    self.mode = mode
    self.status = status
  }

  public init(ref: EntityRef, reading reader: FieldReader<ChatSessionField>) throws(UnreadableReason) {
    guard let id = Self.identity(of: ref) else { throw .identity(ref) }
    self.init(
      unvalidated: id, novel: try reader.required(.novel), title: try reader.optional(.title), autoTitle: try reader.optional(.autoTitle), mode: try reader.required(.mode),
      status: try reader.required(.status))
  }

  public var ref: EntityRef { Self.ref(id) }

  public var displayTitle: String? { title ?? autoTitle }

  public var fields: RecordFields<ChatSessionField> {
    var fields = RecordFields<ChatSessionField>()
    fields.put(.novel, novel)
    fields.put(.title, title)
    fields.put(.autoTitle, autoTitle)
    fields.put(.mode, mode)
    fields.put(.status, status)
    return fields
  }

  // A first-writer-wins member written as null would hold its place for ever, so an untitled session leaves auto_title out.
  public var storedMembers: [String: JSONValue] {
    var members = fields.members
    if autoTitle == nil { members[ChatSessionField.autoTitle.rawValue] = nil }
    members[CommonField.removed.rawValue] = .bool(false)
    return members
  }

  public static func removal(in reader: FieldReader<ChatSessionField>) throws(UnreadableReason) -> Bool {
    try reader.common(.removed)
  }

  public static func owner(of ref: EntityRef, in reader: FieldReader<ChatSessionField>) -> UUID? {
    try? reader.required(.novel)
  }

  private static func identity(of ref: EntityRef) -> UUID? {
    guard ref.kind == kind.entityKind, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { return nil }
    return id
  }
}

public struct ChatSessionEdit: Sendable, Equatable {
  public private(set) var title: FieldChange<String?> = .keep
  public private(set) var autoTitle: FieldChange<String> = .keep
  public private(set) var mode: FieldChange<StoredEnum<ChatSessionMode>> = .keep
  public private(set) var status: FieldChange<StoredEnum<ChatSessionStatus>> = .keep

  public init() {}

  // Deliberate deviation: chat-session.service.ts:67 stores any title, a blank one included; clearing is `rename(nil)`.
  public mutating func rename(_ title: String?) throws(ChatRecordError) {
    self.title = .set(try title.map(validatedChatTitle))
  }

  public mutating func nameAutomatically(_ title: String) throws(ChatRecordError) {
    autoTitle = .set(try validatedChatTitle(title.jsTrim()))
  }

  public mutating func switchMode(to mode: ChatSessionMode) { self.mode = .set(.known(mode)) }

  public mutating func setStatus(_ status: ChatSessionStatus) { self.status = .set(.known(status)) }

  public var fields: RecordFields<ChatSessionField> {
    var fields = RecordFields<ChatSessionField>()
    fields.put(.title, title)
    fields.put(.autoTitle, autoTitle)
    fields.put(.mode, mode)
    fields.put(.status, status)
    return fields
  }
}

extension ChatSessionRecord {
  public static func ref(_ id: UUID) -> EntityRef { NovelForgeKey.chatSession(id) }

  public static func read<Transaction: StateReading & ~Copyable>(id: UUID, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<ChatSessionRecord> {
    try read(ref(id), in: transaction)
  }

  public static func listing<Transaction: StateReading & ~Copyable>(novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> RecordListing<ChatSessionRecord> {
    collecting(try transaction.states(ofKind: kind.entityKind, scope: .vault), owner: novel)
  }

  public static func edit(id: UUID, _ changes: ChatSessionEdit, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try edit(ref(id), changes.fields, in: &transaction)
  }

  public static func remove(id: UUID, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try transaction.set(ref(id), [CommonField.removed.rawValue: .bool(true)])
  }

  // Only the flag: restoring from a stale copy must not write its title, mode or status over a later edit.
  public static func restore(id: UUID, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try transaction.set(ref(id), [CommonField.removed.rawValue: .bool(false)])
  }
}
