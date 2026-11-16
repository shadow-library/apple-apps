import Foundation
import ShadowCore
import ShadowStore

public enum PageSaved: Sendable, Equatable {
  case unchanged
  case created(revision: String)
  case revised(revision: String)
}

public struct PageVersion: Sendable, Equatable {
  public let revision: String
  public let parent: String?
  public let created: HLCTimestamp
  public let isHead: Bool
  public let content: PageContent?
}

public struct PageSummary: Sendable, Equatable {
  public let section: BiblePageSection
  public let slug: String
  public let title: String
  public let wordCount: Int
  public let isEmpty: Bool
  public let writerExcluded: Bool
  public let plannerOnly: Bool
}

// apps/novel-forge-server/src/modules/bible/document/bible-document.service.ts and refinement/apply/bible-document.handler.ts; the chapter revalidation flag is derived from the page heads, not written
public enum Pages {
  // bible-document.service.ts:55: the document is created, or gets a new revision when its content differs; a title is folded into the frontmatter
  @discardableResult
  public static func save(
    novel: UUID, section: BiblePageSection, slug: String, frontmatter: [String: JSONValue]? = nil, body: String? = nil, in transaction: inout WriteTransaction
  ) throws(BibleError) -> PageSaved {
    try requireBibleKey(slug, field: "slug")
    try transaction.requireBibleNovel(novel)
    let record = PageRecord(novel: novel, section: section, slug: slug)
    switch try transaction.biblePresence(record.ref, as: PageRecord.self) {
    case .live(let existing): return try revise(existing, frontmatter, body, in: &transaction)
    case .removed, .absent: return try create(record, folded(record.content, frontmatter, body, slug: record.slug), in: &transaction)
    }
  }

  @discardableResult
  public static func create(
    novel: UUID, section: BiblePageSection, slug: String, frontmatter: [String: JSONValue]? = nil, body: String? = nil, in transaction: inout WriteTransaction
  ) throws(BibleError) -> PageSaved {
    try requireBibleKey(slug, field: "slug")
    try transaction.requireBibleNovel(novel)
    let record = PageRecord(novel: novel, section: section, slug: slug)
    if case .live = try transaction.biblePresence(record.ref, as: PageRecord.self) { throw .documentExists(section: section.rawValue, slug: record.slug) }
    return try create(record, folded(record.content, frontmatter, body, slug: record.slug), in: &transaction)
  }

  @discardableResult
  public static func revise(
    novel: UUID, section: BiblePageSection, slug: String, frontmatter: [String: JSONValue]? = nil, body: String? = nil, in transaction: inout WriteTransaction
  ) throws(BibleError) -> PageSaved {
    let ref = PageRecord.ref(novel: novel, section: section, slug: slug)
    guard case .live(let existing) = try transaction.biblePresence(ref, as: PageRecord.self) else { throw .documentNotFound(section: section.rawValue, slug: slug) }
    return try revise(existing, frontmatter, body, in: &transaction)
  }

  // Newest first; a removed page keeps its versions, an absent one has none
  public static func versions<Transaction: StateReading & ~Copyable>(
    novel: UUID, section: BiblePageSection, slug: String, in transaction: borrowing Transaction
  ) throws(BibleError) -> [PageVersion] {
    let ref = PageRecord.ref(novel: novel, section: section, slug: slug)
    let reading: HistoryReading<PageContent, NoMark>
    do throws(StoreError) {
      reading = try PageRecord.history(novel: novel, section: section, slug: slug, in: transaction)
    } catch {
      throw .store(error)
    }
    switch reading {
    case .absent: throw .documentNotFound(section: section.rawValue, slug: slug)
    case .unreadable: throw .unreadable(ref)
    case .readable(let history):
      return history.revisions.map { PageVersion(revision: $0.id, parent: $0.parent, created: $0.created, isHead: $0.id == history.head, content: $0.body.body) }
    }
  }

  // The older version becomes the content of a new revision; restoring the head writes nothing
  @discardableResult
  public static func restoreVersion(novel: UUID, section: BiblePageSection, slug: String, revision: String, in transaction: inout WriteTransaction) throws(BibleError) -> PageSaved
  {
    let ref = PageRecord.ref(novel: novel, section: section, slug: slug)
    guard case .live(let existing) = try transaction.biblePresence(ref, as: PageRecord.self) else { throw .documentNotFound(section: section.rawValue, slug: slug) }
    guard let version = try versions(novel: novel, section: section, slug: slug, in: transaction).first(where: { $0.revision == revision }) else {
      throw .revisionNotFound(revision)
    }
    guard let content = version.content else { throw .revisionUnreadable(revision) }
    guard !version.isHead else { return .unchanged }
    var restored = existing.content
    restored.frontmatter = content.frontmatter
    restored.body = content.body
    return try revise(existing, restored, in: &transaction)
  }

  // bible-document.handler.ts:55: the reference deletes the row; the record is marked removed and keeps its versions
  public static func remove(novel: UUID, section: BiblePageSection, slug: String, in transaction: inout WriteTransaction) throws(BibleError) {
    let ref = PageRecord.ref(novel: novel, section: section, slug: slug)
    guard case .live = try transaction.biblePresence(ref, as: PageRecord.self) else { throw .documentNotFound(section: section.rawValue, slug: slug) }
    try transaction.bibleRemove(PageRecord.self, ref)
  }

  public static func restore(novel: UUID, section: BiblePageSection, slug: String, in transaction: inout WriteTransaction) throws(BibleError) {
    switch try transaction.biblePresence(PageRecord.ref(novel: novel, section: section, slug: slug), as: PageRecord.self) {
    case .removed(let record): try transaction.bibleRestore(record)
    case .live: return
    case .absent: throw .documentNotFound(section: section.rawValue, slug: slug)
    }
  }

  // bible-document.service.ts:47
  public static func get<Transaction: StateReading & ~Copyable>(novel: UUID, section: BiblePageSection, slug: String, in transaction: borrowing Transaction) throws(BibleError)
    -> PageRecord?
  {
    let ref = PageRecord.ref(novel: novel, section: section, slug: slug)
    let reading: RecordReading<PageRecord>
    do throws(StoreError) {
      reading = try PageRecord.read(novel: novel, section: section, slug: slug, in: transaction)
    } catch {
      throw .store(error)
    }
    guard let found = try bibleReading(reading, ref: ref), !found.isRemoved else { return nil }
    return found.record
  }

  // bible-document.service.ts:26: by section in the stored order, then slug; pages of a section this version does not know are skipped
  public static func list<Transaction: StateReading & ~Copyable>(novel: UUID, section: BiblePageSection? = nil, in transaction: borrowing Transaction) throws(BibleError)
    -> [PageSummary]
  {
    let listing: RecordListing<PageRecord>
    do throws(StoreError) {
      listing = try PageRecord.listing(novel: novel, in: transaction)
    } catch {
      throw .store(error)
    }
    let order = BiblePageSection.allCases
    return listing.live
      .filter { page in section.map { page.section == $0 } ?? true }
      .sorted { left, right in
        guard left.section == right.section else { return (order.firstIndex(of: left.section) ?? order.count) < (order.firstIndex(of: right.section) ?? order.count) }
        return JSText.codeUnitPrecedes(left.slug, right.slug)
      }
      .map(summary)
  }

  public static func title(of page: PageRecord) -> String {
    BibleTitle.derive(slug: page.slug, frontmatter: page.content.frontmatter, body: page.content.body)
  }

  public static func requiredEntityTypes(section: BiblePageSection, slug: String) -> [EntityType] {
    requiredEntityTypesForSlug(section: section.rawValue, slug: slug)
  }

  private static func summary(of page: PageRecord) -> PageSummary {
    let access = bibleDocAccess(BibleDocAddress(section: page.section.rawValue, slug: page.slug))
    let body = page.content.body ?? ""
    return PageSummary(
      section: page.section, slug: page.slug, title: title(of: page), wordCount: ProseMetrics.countWords(body), isEmpty: body.jsTrim().isEmpty,
      writerExcluded: access.writerExcluded,
      plannerOnly: access.plannerOnly)
  }

  private static func folded(_ content: PageContent, _ frontmatter: [String: JSONValue]?, _ body: String?, slug: String) -> PageContent {
    var folded = content
    folded.frontmatter = BibleTitle.ensure(slug: slug, frontmatter: frontmatter, body: body)
    folded.body = body
    return folded
  }

  private static func create(_ record: PageRecord, _ content: PageContent, in transaction: inout WriteTransaction) throws(BibleError) -> PageSaved {
    var page = record
    page.content = content
    try transaction.bibleCreate(page)
    return .created(revision: try headRevision(of: page, in: transaction))
  }

  private static func revise(_ existing: PageRecord, _ frontmatter: [String: JSONValue]?, _ body: String?, in transaction: inout WriteTransaction) throws(BibleError) -> PageSaved {
    var raw = existing.content
    raw.frontmatter = frontmatter
    raw.body = body
    guard raw != existing.content else { return .unchanged }
    return try revise(existing, folded(existing.content, frontmatter, body, slug: existing.slug), in: &transaction)
  }

  private static func revise(_ existing: PageRecord, _ content: PageContent, in transaction: inout WriteTransaction) throws(BibleError) -> PageSaved {
    guard content != existing.content else { return .unchanged }
    do throws(StoreError) {
      return .revised(revision: try PageRecord.revise(novel: existing.novel, section: existing.section, slug: existing.slug, content, in: &transaction).revision)
    } catch {
      throw .store(error)
    }
  }

  private static func headRevision(of page: PageRecord, in transaction: borrowing WriteTransaction) throws(BibleError) -> String {
    let versions = try versions(novel: page.novel, section: page.section, slug: page.slug, in: transaction)
    guard let head = versions.first(where: \.isHead) else { throw .unreadable(page.ref) }
    return head.revision
  }
}
