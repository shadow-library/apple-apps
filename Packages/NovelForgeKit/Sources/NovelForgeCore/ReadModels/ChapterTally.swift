import Foundation
import GRDB
import ShadowStore

public struct ChapterTally: Sendable, Equatable {
  public let known: Int
  public let finals: Int
  public let drafted: Int
  public let approved: Int
  public let stale: Int
  public let next: Int

  static let tables = [ChapterLifecycleEntry.databaseTableName, StoryCursor.databaseTableName]

  static func load(novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChapterTally {
    let counts = try transaction.query { database in
      try Row.fetchOne(
        database,
        sql: """
          SELECT COUNT(*) AS known, COUNT(*) FILTER (WHERE final) AS finals, COUNT(*) FILTER (WHERE NOT final AND draft IS NOT NULL) AS drafted,
            COUNT(*) FILTER (WHERE NOT final AND review = 'approved') AS approved, COUNT(*) FILTER (WHERE NOT final AND stale IS NOT NULL) AS stale
          FROM nf_derived_chapter_lifecycle WHERE novel = ?
          """, arguments: [novel])
    }
    let next = try transaction.query { database in try StoryCursor.filter(Column("novel") == novel).fetchOne(database)?.chapter }
    return ChapterTally(
      known: counts?["known"] ?? 0, finals: counts?["finals"] ?? 0, drafted: counts?["drafted"] ?? 0, approved: counts?["approved"] ?? 0, stale: counts?["stale"] ?? 0,
      next: next ?? 1)
  }
}
