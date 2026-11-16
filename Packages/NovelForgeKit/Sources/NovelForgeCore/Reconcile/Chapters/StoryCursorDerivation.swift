import Foundation
import GRDB
import ShadowStore

public struct StoryCursor: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_story_cursor"

  public let novel: UUID
  public let chapter: Int
}

public struct StoryCursorDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_story_cursor (novel BLOB PRIMARY KEY, chapter INTEGER NOT NULL) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [
      .records([.novel]) { ref in novelID(of: ref).map { [$0] } ?? [] },
      .outputs(of: FinalChapterDerivation.self) { [$0.novel] },
    ]
  }

  public static func key(of output: StoryCursor) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<StoryCursor> {
    StoryCursor.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    let finals = try context.fetchAll(FinalChapterEntry.all()).map(\.novel)
    return Set(try context.refs(of: .novel).compactMap(novelID(of:)) + finals)
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [StoryCursor] {
    let chapters = try context.fetchAll(FinalChapterEntry.filter(Column("novel") == novel).order(Column("chapter"))).map(\.chapter)
    let exists = try NovelRecord.read(NovelForgeKey.novel(novel), in: context.records) != .absent
    guard exists || !chapters.isEmpty else { return [] }
    return [StoryCursor(novel: novel, chapter: Self.firstNotFinal(among: chapters))]
  }

  static func firstNotFinal(among ascending: [Int]) -> Int {
    var next = 1
    for chapter in ascending where chapter >= next {
      guard chapter == next, next < Int.max else { break }
      next += 1
    }
    return next
  }
}
