import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// What an autosave keeps on this device only, over the draft revision it continues (orchestrator decision 6). It is a table of the app's own beside the
/// vault, written through the write transaction's database: nothing in it syncs, and a reset of the derived tables leaves it alone.
public struct DraftWorkingCopy: Sendable, Equatable {
  public let novel: UUID
  public let chapter: Int
  public let base: String
  public let content: DraftContent

  static let table = "nf_local_draft_working_copy"
  private static let definition = """
    CREATE TABLE IF NOT EXISTS nf_local_draft_working_copy (
      novel BLOB NOT NULL, chapter INTEGER NOT NULL, base TEXT NOT NULL, content BLOB NOT NULL, PRIMARY KEY (novel, chapter)
    ) STRICT, WITHOUT ROWID
    """

  /// The working copy this device holds for the chapter; nil when it holds none or one this version cannot read.
  public static func read(novel: UUID, chapter: Int, in database: Database) throws(StoreError) -> DraftWorkingCopy? {
    do {
      guard try database.tableExists(table) else { return nil }
      let row = try Row.fetchOne(database, sql: "SELECT base, content FROM \(table) WHERE novel = ? AND chapter = ?", arguments: [novel, chapter])
      guard let row, let bytes = try? row.decode(Data.self, forColumn: "content"), let json = try? CanonicalJSON.decode(bytes), let content = DraftContent(json: json),
        let base = try? row.decode(String.self, forColumn: "base")
      else { return nil }
      return DraftWorkingCopy(novel: novel, chapter: chapter, base: base, content: content)
    } catch {
      throw StoreError(projecting: error)
    }
  }

  func save(in database: Database) throws(StoreError) {
    do {
      try database.execute(sql: Self.definition)
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(Self.table) (novel, chapter, base, content) VALUES (?, ?, ?, ?)",
        arguments: [novel, chapter, base, CanonicalJSON.encode(content.json)])
    } catch {
      throw StoreError(projecting: error)
    }
  }

  static func discard(novel: UUID, chapter: Int, in database: Database) throws(StoreError) {
    do {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE novel = ? AND chapter = ?", arguments: [novel, chapter])
    } catch {
      throw StoreError(projecting: error)
    }
  }
}
