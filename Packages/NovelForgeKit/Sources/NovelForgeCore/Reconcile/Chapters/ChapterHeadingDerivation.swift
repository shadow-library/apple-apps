import Foundation
import GRDB
import ShadowStore

struct ChapterHeadingKey: Hashable, Sendable {
  let novel: UUID
  let chapter: Int
}

/// The title a chapter is listed under and the volume it claims.
struct ChapterHeadingEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "nf_derived_chapter_heading"

  let novel: UUID
  let chapter: Int
  let title: String?
  let volume: String?

  init(novel: UUID, chapter: Int, title: String?, volume: String?) {
    self.novel = novel
    self.chapter = chapter
    self.title = title
    self.volume = volume
  }

  init(row: Row) throws {
    self.init(
      novel: try row.decode(UUID.self, forColumn: "novel"), chapter: try row.decode(Int.self, forColumn: "chapter"),
      title: try row.decode(String?.self, forColumn: "title"), volume: try row.decode(String?.self, forColumn: "volume"))
  }

  var key: ChapterHeadingKey { ChapterHeadingKey(novel: novel, chapter: chapter) }

  func encode(to container: inout PersistenceContainer) throws {
    container["novel"] = novel
    container["chapter"] = chapter
    container["title"] = title
    container["volume"] = volume
  }
}

// The title comes from the final chapter, else the draft head, else the plan head; the volume from the canon, else the plan head.
struct ChapterHeadingDerivation: Derivation {
  static let version = 1
  static let definition = """
    CREATE TABLE nf_derived_chapter_heading (
      novel BLOB NOT NULL, chapter INTEGER NOT NULL, title TEXT, volume TEXT, PRIMARY KEY (novel, chapter)
    ) STRICT, WITHOUT ROWID;
    """

  var inputs: [DerivationInput<ChapterHeadingKey>] {
    [.outputs(of: ChapterHeadingSourceDerivation.self) { [ChapterHeadingKey(novel: $0.novel, chapter: $0.chapter)] }]
  }

  static func key(of output: ChapterHeadingEntry) -> ChapterHeadingKey { output.key }

  static func request(for key: ChapterHeadingKey) -> QueryInterfaceRequest<ChapterHeadingEntry> {
    ChapterHeadingEntry.filter(Column("novel") == key.novel && Column("chapter") == key.chapter)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<ChapterHeadingKey> {
    Set(try context.fetchAll(ChapterHeadingSource.all()).map { ChapterHeadingKey(novel: $0.novel, chapter: $0.chapter) })
  }

  func outputs(for key: ChapterHeadingKey, in context: DerivationContext) throws(StoreError) -> [ChapterHeadingEntry] {
    let sources = try context.fetchAll(ChapterHeadingSource.filter(Column("novel") == key.novel && Column("chapter") == key.chapter))
    guard !sources.isEmpty else { return [] }
    let ordered = sources.sorted { (Self.rank($0.kind), $0.key.rawValue) < (Self.rank($1.kind), $1.key.rawValue) }
    return [
      ChapterHeadingEntry(novel: key.novel, chapter: key.chapter, title: ordered.lazy.compactMap(\.title).first, volume: ordered.lazy.compactMap(\.volume).first)
    ]
  }

  private static func rank(_ kind: NovelForgeKind) -> Int {
    switch kind {
    case .finalChapter: 0
    case .draft: 1
    default: 2
    }
  }
}
