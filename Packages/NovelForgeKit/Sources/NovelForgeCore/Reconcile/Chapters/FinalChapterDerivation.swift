import Foundation
import GRDB
import ShadowStore

public struct FinalChapterEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_final_chapter"

  public let key: EntityKey
  public let novel: UUID
  public let chapter: Int
  public let isReadable: Bool

  init(key: EntityKey, novel: UUID, chapter: Int, isReadable: Bool) {
    self.key = key
    self.novel = novel
    self.chapter = chapter
    self.isReadable = isReadable
  }

  public init(row: Row) throws {
    guard let key = EntityKey(try row.decode(String.self, forColumn: "key")) else { throw StoreError.corruptStore("a final chapter entry holds an invalid key") }
    self.init(
      key: key, novel: try row.decode(UUID.self, forColumn: "novel"), chapter: try row.decode(Int.self, forColumn: "chapter"),
      isReadable: try row.decode(Bool.self, forColumn: "readable"))
  }

  public var ref: EntityRef { EntityRef(kind: NovelForgeKind.finalChapter.entityKind, key: key) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["key"] = key.rawValue
    container["novel"] = novel
    container["chapter"] = chapter
    container["readable"] = isReadable
  }
}

// A chapter is final when its canon exists, so a canon this version cannot read still counts, marked unreadable.
public struct FinalChapterDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_final_chapter (key TEXT PRIMARY KEY, novel BLOB NOT NULL, chapter INTEGER NOT NULL, readable INTEGER NOT NULL) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_final_chapter_novel ON nf_derived_final_chapter (novel, chapter);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.records([.finalChapter]) { [$0] }]
  }

  public static func key(of output: FinalChapterEntry) -> EntityRef {
    output.ref
  }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<FinalChapterEntry> {
    FinalChapterEntry.filter(Column("key") == ref.key.rawValue)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .finalChapter))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [FinalChapterEntry] {
    let state = try context.records.state(of: ref, scope: .vault)
    switch FinalChapterRecord.reading(state, of: ref) {
    case .absent:
      return []
    case .readable(let entry):
      return [FinalChapterEntry(key: ref.key, novel: entry.record.novel, chapter: entry.record.chapter, isReadable: true)]
    case .unreadable:
      guard let state, let key = try? NovelForgeKey(reading: state, of: ref), case .finalChapter(let chapter) = key.components else { return [] }
      return [FinalChapterEntry(key: ref.key, novel: key.novel, chapter: chapter, isReadable: false)]
    }
  }
}
