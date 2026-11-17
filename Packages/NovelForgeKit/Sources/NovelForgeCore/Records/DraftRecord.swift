import Foundation
import ShadowCore
import ShadowStore

extension DraftMark: FieldName {}

// apps/novel-forge-server/src/database/schemas/projects.ts:43
public enum ContentGenerator: String, CaseIterable, Sendable {
  case standard
  case unrestricted
  case human
}

// apps/novel-forge-server/src/database/schemas/ai.ts:76
public enum DraftSource: String, CaseIterable, Sendable {
  case generated
  case patched
  case rewritten
  case revised
  case imported
  case handEdited = "hand_edited"
  case chatEdited = "chat_edited"
  case amended
  case restored
  case passageRewritten = "passage_rewritten"
}

enum DraftContentMember: String, CaseIterable, FieldName {
  case title
  case body
  case summary
  case source
  case generator
  case isolated
  case restoredFrom = "restored_from"
  case upstream
}

// apps/novel-forge-server/src/database/schemas/ai.ts:267; the review status, stale reason and word count are derived, never stored
public struct DraftContent: RevisionBody, Sendable {
  public var title: String?
  public var body: String
  public var summary: String?
  public var source: StoredEnum<DraftSource>
  public var generator: StoredEnum<ContentGenerator>
  public var isolated: Bool
  public var restoredFrom: String?
  public private(set) var unrecognised: [String: JSONValue]
  /// Kept as stored, so a shape this version cannot read still round-trips and never hides the prose.
  private var storedUpstream: JSONValue

  public init(
    title: String? = nil, body: String, summary: String? = nil, source: StoredEnum<DraftSource>, generator: StoredEnum<ContentGenerator> = .known(.standard),
    isolated: Bool = false, restoredFrom: String? = nil, upstream: DraftUpstream? = nil
  ) {
    self.title = title
    self.body = body
    self.summary = summary
    self.source = source
    self.generator = generator
    self.isolated = isolated
    self.restoredFrom = restoredFrom
    storedUpstream = upstream.json
    unrecognised = [:]
  }

  /// What the revision was written against (`ChapterFingerprint` rule 2); nil when it records nothing this version can read, which the lifecycle shows as stale.
  public var upstream: DraftUpstream? {
    get { DraftUpstream(json: storedUpstream) }
    set { storedUpstream = newValue.json }
  }

  public init?(json: JSONValue) {
    guard let reader = FieldReader<DraftContentMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        title: try reader.optional(.title), body: try reader.required(.body), summary: try reader.optional(.summary), source: try reader.required(.source),
        generator: try reader.required(.generator), isolated: try reader.required(.isolated), restoredFrom: try reader.optional(.restoredFrom))
    } catch {
      return nil
    }
    let upstream: JSONValue? = try? reader.optional(.upstream)
    storedUpstream = upstream ?? .null
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<DraftContentMember>()
    fields.put(.title, title)
    fields.put(.body, body)
    fields.put(.summary, summary)
    fields.put(.source, source)
    fields.put(.generator, generator)
    fields.put(.isolated, isolated)
    fields.put(.restoredFrom, restoredFrom)
    fields.put(.upstream, storedUpstream)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// The `approved` mark only keeps a revision from being pruned; the approval in force comes from the approval items.
public struct DraftRecord: DocumentRecord, RemovableRecord {
  public typealias Body = DraftContent
  public typealias Mark = DraftMark

  public static let kind = NovelForgeKind.draft

  public let key: NovelForgeKey
  public let chapter: Int
  public var content: DraftContent

  public init(novel: UUID, chapter: Int, content: DraftContent) throws(NovelForgeKeyError) {
    key = try .draftKey(novel: novel, chapter: chapter)
    self.chapter = chapter
    self.content = content
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<DocumentField>) throws(UnreadableReason) {
    guard case .draft(let chapter) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.key = key
    self.chapter = chapter
    content = try reader.head()
  }
}

extension DraftRecord {
  public static func ref(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try NovelForgeKey.draft(novel: novel, chapter: chapter) }

  public static func revise(_ ref: EntityRef, _ content: DraftContent, marks: [DraftMark] = [], in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    try revise(ref, body: content, marks: marks, in: &transaction)
  }

  /// A revision beside the head, child of `parent`, that does not become the head.
  public static func keep(_ ref: EntityRef, _ content: DraftContent, parent: RevisionParent, in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    try revise(ref, body: content, parent: parent, head: false, in: &transaction)
  }

  public static func mark(_ ref: EntityRef, revision: String, _ marks: [DraftMark], in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try mark(ref, revision: revision, as: marks, in: &transaction)
  }

  public static func history<Transaction: StateReading & ~Copyable>(_ ref: EntityRef, in transaction: borrowing Transaction) throws(StoreError) -> HistoryReading<
    DraftContent, DraftMark
  > {
    try history(of: ref, in: transaction)
  }
}
