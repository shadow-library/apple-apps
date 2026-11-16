import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// One draft as the chapter lifecycle reads it, so a per-novel pass never decodes a draft body again. `upstream` is the canonical JSON of the head's recorded
/// upstream, nil when the head records none this version can read.
struct ChapterDraftEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "nf_derived_chapter_draft"

  let key: EntityKey
  let novel: UUID
  let chapter: Int
  let readable: Bool
  let head: String?
  let source: String?
  let upstream: String?

  init(key: EntityKey, novel: UUID, chapter: Int, readable: Bool, head: String?, source: String?, upstream: String?) {
    self.key = key
    self.novel = novel
    self.chapter = chapter
    self.readable = readable
    self.head = head
    self.source = source
    self.upstream = upstream
  }

  init(row: Row) throws {
    guard let key = EntityKey(try row.decode(String.self, forColumn: "key")) else { throw StoreError.corruptStore("a chapter draft entry holds an invalid key") }
    self.init(
      key: key, novel: try row.decode(UUID.self, forColumn: "novel"), chapter: try row.decode(Int.self, forColumn: "chapter"),
      readable: try row.decode(Bool.self, forColumn: "readable"), head: try row.decode(String?.self, forColumn: "head"),
      source: try row.decode(String?.self, forColumn: "source"), upstream: try row.decode(String?.self, forColumn: "upstream"))
  }

  var ref: EntityRef { EntityRef(kind: NovelForgeKind.draft.entityKind, key: key) }

  /// Stored bytes that no longer parse count as no record, which only ever adds a stale mark.
  var recordedUpstream: DraftUpstream? {
    guard let upstream, let json = try? CanonicalJSON.decode(Data(upstream.utf8)) else { return nil }
    return DraftUpstream(json: json)
  }

  func encode(to container: inout PersistenceContainer) throws {
    container["key"] = key.rawValue
    container["novel"] = novel
    container["chapter"] = chapter
    container["readable"] = readable
    container["head"] = head
    container["source"] = source
    container["upstream"] = upstream
  }
}

// One row per draft that is not removed; a draft this version cannot read still counts as written, with its head and no recorded upstream.
struct ChapterDraftDerivation: Derivation {
  static let version = 1
  static let definition = """
    CREATE TABLE nf_derived_chapter_draft (
      key TEXT PRIMARY KEY, novel BLOB NOT NULL, chapter INTEGER NOT NULL, readable INTEGER NOT NULL, head TEXT, source TEXT, upstream TEXT
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_chapter_draft_novel ON nf_derived_chapter_draft (novel, chapter);
    """

  var inputs: [DerivationInput<EntityRef>] {
    [.records([.draft]) { [$0] }]
  }

  static func key(of output: ChapterDraftEntry) -> EntityRef { output.ref }

  static func request(for ref: EntityRef) -> QueryInterfaceRequest<ChapterDraftEntry> {
    ChapterDraftEntry.filter(Column("key") == ref.key.rawValue)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .draft))
  }

  func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ChapterDraftEntry] {
    let state = try context.records.state(of: ref, scope: .vault)
    guard case .revisioned(let revisioned)? = state else { return [] }
    switch DraftRecord.reading(state, of: ref) {
    case .absent:
      return []
    case .readable(let entry):
      guard !entry.isRemoved else { return [] }
      let content = entry.record.content
      let upstream = content.upstream.map { String(decoding: CanonicalJSON.encode($0.json), as: UTF8.self) }
      return [
        ChapterDraftEntry(
          key: ref.key, novel: entry.record.novel, chapter: entry.record.chapter, readable: true, head: revisioned.headRevision, source: content.source.rawValue,
          upstream: upstream)
      ]
    case .unreadable:
      guard let state, let key = try? NovelForgeKey(reading: state, of: ref), case .draft(let chapter) = key.components else { return [] }
      return [ChapterDraftEntry(key: ref.key, novel: key.novel, chapter: chapter, readable: false, head: revisioned.headRevision, source: nil, upstream: nil)]
    }
  }
}
