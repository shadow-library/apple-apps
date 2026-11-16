import Foundation
import ShadowCore
import ShadowStore

enum AuthorNotesContentMember: String, CaseIterable, FieldName {
  case text
}

// apps/novel-forge-server/src/modules/notes/organise-context.ts:41 reads the author's own words
public struct AuthorNotesContent: RevisionBody, Sendable {
  public var text: String
  public private(set) var unrecognised: [String: JSONValue]

  public init(text: String) {
    self.text = text
    unrecognised = [:]
  }

  public init?(json: JSONValue) {
    guard let reader = FieldReader<AuthorNotesContentMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      text = try reader.required(.text)
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<AuthorNotesContentMember>()
    fields.put(.text, text)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

public struct AuthorNotesRecord: DocumentRecord {
  public typealias Body = AuthorNotesContent

  public static let kind = NovelForgeKind.authorNotes

  public let key: NovelForgeKey
  public var content: AuthorNotesContent

  public init(novel: UUID, content: AuthorNotesContent) {
    key = .authorNotesKey(novel: novel)
    self.content = content
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<DocumentField>) throws(UnreadableReason) {
    guard case .authorNotes = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.init(novel: key.novel, content: try reader.head())
  }
}

extension AuthorNotesRecord {
  public static func ref(novel: UUID) -> EntityRef { NovelForgeKey.authorNotes(novel: novel) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<AuthorNotesRecord> {
    try read(ref(novel: novel), in: transaction)
  }

  public static func revise(novel: UUID, _ content: AuthorNotesContent, in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    try revise(ref(novel: novel), body: content, in: &transaction)
  }

  public static func history<Transaction: StateReading & ~Copyable>(novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> HistoryReading<
    AuthorNotesContent, NoMark
  > {
    try history(of: ref(novel: novel), in: transaction)
  }
}
