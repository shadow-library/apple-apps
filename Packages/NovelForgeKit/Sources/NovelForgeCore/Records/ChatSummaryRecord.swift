import Foundation
import ShadowCore
import ShadowStore

extension ChatSummaryMember: FieldName {}

// apps/novel-forge-server/src/modules/refinement/chat-compaction.service.ts:142-168 folds the oldest turns into a summary; here each fold is an item, so the newest one covering the most is derived
public struct ChatSummaryRecord: AppendedRecord {
  public static let kind = NovelForgeKind.chatSummary
  public static let novelMember = ChatSummaryMember.novel

  public let id: UUID
  public let novel: UUID
  public let session: UUID
  public let covered: [UUID]
  public let text: String
  public let contentMode: StoredEnum<ContentMode>
  public private(set) var unrecognised: [String: JSONValue]

  // chat-compaction.service.ts:155 skips a fold that produced no summary
  public init(id: UUID = UUID(), novel: UUID, session: UUID, covered: [UUID], text: String, contentMode: ContentMode) throws(ChatRecordError) {
    guard !covered.isEmpty else { throw .noCoveredMessages }
    guard !text.isEmpty else { throw .blankSummary }
    self.init(unvalidated: id, novel: novel, session: session, covered: covered, text: text, contentMode: .known(contentMode))
  }

  private init(unvalidated id: UUID, novel: UUID, session: UUID, covered: [UUID], text: String, contentMode: StoredEnum<ContentMode>) {
    self.id = id
    self.novel = novel
    self.session = session
    self.covered = covered
    self.text = text
    self.contentMode = contentMode
    unrecognised = [:]
  }

  public init(id: UUID, reading reader: FieldReader<ChatSummaryMember>) throws(UnreadableReason) {
    self.init(
      unvalidated: id, novel: try reader.required(.novel), session: try reader.required(.session), covered: try reader.required(.covered), text: try reader.required(.text),
      contentMode: try reader.required(.contentMode))
    unrecognised = reader.unrecognised
  }

  public var members: RecordFields<ChatSummaryMember> {
    var fields = RecordFields<ChatSummaryMember>()
    fields.put(.novel, novel)
    fields.put(.session, session)
    fields.put(.covered, covered)
    fields.put(.text, text)
    fields.put(.contentMode, contentMode)
    return fields
  }
}

extension ChatSummaryRecord {
  public static func listing<Transaction: StateReading & ~Copyable>(session: UUID, novel: UUID, in transaction: borrowing Transaction) throws(StoreError)
    -> AppendedListing<ChatSummaryRecord>
  {
    collecting(try transaction.states(ofKind: kind.entityKind, scope: .vault), owner: novel) { reader in
      let stored: UUID? = try? reader.required(.session)
      return stored.map { $0 == session } ?? true
    }
  }
}
