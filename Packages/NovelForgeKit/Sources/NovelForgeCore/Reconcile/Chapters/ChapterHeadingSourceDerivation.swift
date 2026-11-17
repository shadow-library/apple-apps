import Foundation
import GRDB
import ShadowStore

/// What one final chapter, draft or plan gives its chapter's heading, so the heading never decodes a chapter again.
struct ChapterHeadingSource: Hashable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "nf_derived_chapter_heading_source"

  let kind: NovelForgeKind
  let key: EntityKey
  let novel: UUID
  let chapter: Int
  let title: String?
  let volume: String?

  init(kind: NovelForgeKind, key: EntityKey, novel: UUID, chapter: Int, title: String?, volume: String?) {
    self.kind = kind
    self.key = key
    self.novel = novel
    self.chapter = chapter
    self.title = title
    self.volume = volume
  }

  init(row: Row) throws {
    guard let key = EntityKey(try row.decode(String.self, forColumn: "key")) else { throw StoreError.corruptStore("a chapter heading source holds an invalid key") }
    self.init(
      kind: try row.decode(NovelForgeKind.self, forColumn: "kind"), key: key, novel: try row.decode(UUID.self, forColumn: "novel"),
      chapter: try row.decode(Int.self, forColumn: "chapter"), title: try row.decode(String?.self, forColumn: "title"),
      volume: try row.decode(String?.self, forColumn: "volume"))
  }

  var ref: EntityRef { EntityRef(kind: kind.entityKind, key: key) }

  func encode(to container: inout PersistenceContainer) throws {
    container["kind"] = kind
    container["key"] = key.rawValue
    container["novel"] = novel
    container["chapter"] = chapter
    container["title"] = title
    container["volume"] = volume
  }
}

// One row per readable record that is not removed and names a title or a volume; a final chapter's title follows its amendment bound to the canon that stands.
struct ChapterHeadingSourceDerivation: Derivation {
  static let version = 1
  static let definition = """
    CREATE TABLE nf_derived_chapter_heading_source (
      kind TEXT NOT NULL, key TEXT NOT NULL, novel BLOB NOT NULL, chapter INTEGER NOT NULL, title TEXT, volume TEXT, PRIMARY KEY (kind, key)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_chapter_heading_source_chapter ON nf_derived_chapter_heading_source (novel, chapter);
    """

  static let kinds: [NovelForgeKind] = [.finalChapter, .draft, .chapterPlan]

  var inputs: [DerivationInput<EntityRef>] {
    [.records(Self.kinds) { [$0] }]
  }

  static func key(of output: ChapterHeadingSource) -> EntityRef { output.ref }

  static func request(for ref: EntityRef) -> QueryInterfaceRequest<ChapterHeadingSource> {
    ChapterHeadingSource.filter(Column("kind") == ref.kind.rawValue && Column("key") == ref.key.rawValue)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    var refs = Set<EntityRef>()
    for kind in Self.kinds { refs.formUnion(try context.refs(of: kind)) }
    return refs
  }

  func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ChapterHeadingSource] {
    switch NovelForgeKind(ref.kind) {
    case .finalChapter:
      guard case .readable(let entry) = try FinalChapterRecord.read(ref, in: context.records), !entry.isRemoved else { return [] }
      return Self.source(.finalChapter, ref, novel: entry.record.novel, chapter: entry.record.chapter, title: entry.record.text.title, volume: entry.record.canon.volume)
    case .draft:
      guard case .readable(let entry) = try DraftRecord.readHead(ref, in: context.records), !entry.isRemoved else { return [] }
      return Self.source(.draft, ref, novel: entry.record.novel, chapter: entry.record.chapter, title: entry.record.content.title, volume: nil)
    case .chapterPlan:
      guard case .readable(let entry) = try ChapterPlanRecord.readHead(ref, in: context.records), !entry.isRemoved else { return [] }
      let content = entry.record.content
      return Self.source(.chapterPlan, ref, novel: entry.record.novel, chapter: entry.record.chapter, title: content.title, volume: content.volume)
    default:
      return []
    }
  }

  private static func source(_ kind: NovelForgeKind, _ ref: EntityRef, novel: UUID, chapter: Int, title: String?, volume: String?) -> [ChapterHeadingSource] {
    guard title != nil || volume != nil else { return [] }
    return [ChapterHeadingSource(kind: kind, key: ref.key, novel: novel, chapter: chapter, title: title, volume: volume)]
  }
}
