import Foundation
import ShadowCore
import ShadowStore

enum PageContentMember: String, CaseIterable, FieldName {
  case frontmatter
  case body
}

// apps/novel-forge-server/src/database/schemas/bible.ts:23
public struct PageContent: RevisionBody, Sendable {
  public var frontmatter: [String: JSONValue]?
  public var body: String?
  public private(set) var unrecognised: [String: JSONValue]

  public init(frontmatter: [String: JSONValue]? = nil, body: String? = nil) {
    self.frontmatter = frontmatter
    self.body = body
    unrecognised = [:]
  }

  public init?(json: JSONValue) {
    guard let reader = FieldReader<PageContentMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      frontmatter = try reader.optional(.frontmatter)
      body = try reader.optional(.body)
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<PageContentMember>()
    fields.put(.frontmatter, frontmatter)
    fields.put(.body, body)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

public struct PageRecord: DocumentRecord, RemovableRecord {
  public typealias Body = PageContent

  public static let kind = NovelForgeKind.page

  public let key: NovelForgeKey
  public let section: BiblePageSection
  public let slug: String
  public var content: PageContent

  public init(novel: UUID, section: BiblePageSection, slug: String, content: PageContent = PageContent()) {
    let slug = slug.precomposedStringWithCanonicalMapping
    self.section = section
    self.slug = slug
    key = .pageKey(novel: novel, section: section, slug: slug)
    self.content = content
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<DocumentField>) throws(UnreadableReason) {
    guard case .page(let stored, let slug) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    guard case .known(let section) = stored else { throw .unknownSection(stored.rawValue) }
    self.init(novel: key.novel, section: section, slug: slug, content: try reader.head())
  }
}

extension PageRecord {
  public static func ref(novel: UUID, section: BiblePageSection, slug: String) -> EntityRef { NovelForgeKey.page(novel: novel, section: section, slug: slug) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, section: BiblePageSection, slug: String, in transaction: borrowing Transaction) throws(StoreError)
    -> RecordReading<PageRecord>
  {
    try read(ref(novel: novel, section: section, slug: slug), in: transaction)
  }

  public static func revise(novel: UUID, section: BiblePageSection, slug: String, _ content: PageContent, in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    try revise(ref(novel: novel, section: section, slug: slug), body: content, in: &transaction)
  }

  public static func history<Transaction: StateReading & ~Copyable>(novel: UUID, section: BiblePageSection, slug: String, in transaction: borrowing Transaction) throws(StoreError)
    -> HistoryReading<PageContent, NoMark>
  {
    try history(of: ref(novel: novel, section: section, slug: slug), in: transaction)
  }

  public static func remove(novel: UUID, section: BiblePageSection, slug: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try remove(ref(novel: novel, section: section, slug: slug), in: &transaction)
  }
}
