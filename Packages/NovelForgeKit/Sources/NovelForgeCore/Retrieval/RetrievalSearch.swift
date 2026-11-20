import Foundation
import GRDB
import ShadowStore

/// BM25 over the FTS5 tables; a hit's score is the negated `bm25()`, so higher is better and never below zero.
enum RetrievalSearch {
  static func prose(novel: UUID, query: RetrievalQuery, k: Int, in transaction: ReadTransaction) throws(StoreError) -> [RetrievalHit] {
    guard k > 0, let match = query.matchExpression else { return [] }
    let ranked = try transaction.query { database -> [(id: Int64, chapter: Int, score: Double)] in
      guard try RetrievalTables.exist(in: database) else { return [] }
      let search = RetrievalTables.proseSearch
      return try Row.fetchAll(
        database,
        sql: """
          SELECT p.id, p.chapter, -bm25(\(search)) AS score FROM \(search) JOIN \(RetrievalTables.prose) p ON p.id = \(search).rowid
          WHERE \(search) MATCH ? AND p.novel = ? ORDER BY score DESC, p.chapter, p.ordinal
          """,
        arguments: [match, novel]
      ).map { (id: $0["id"], chapter: $0["chapter"], score: $0["score"]) }
    }
    var isolation = ChapterIsolation(novel: novel)
    var kept: [(id: Int64, chapter: Int, score: Double)] = []
    for row in ranked where kept.count < k {
      if try !isolation.isIsolated(row.chapter, in: transaction) { kept.append(row) }
    }
    return try transaction.query { database in
      try kept.compactMap { row in
        try String.fetchOne(database, sql: "SELECT text FROM \(RetrievalTables.prose) WHERE id = ?", arguments: [row.id])
          .map { RetrievalHit(text: $0, score: row.score, origin: .prose(chapter: row.chapter)) }
      }
    }
  }

  /// An empty `kinds` filters nothing, as in the reference; any other list is bound value by value, so an unknown kind only matches nothing.
  static func lore(novel: UUID, query: RetrievalQuery, k: Int, kinds: [String]?, in transaction: ReadTransaction) throws(StoreError) -> [RetrievalHit] {
    guard k > 0, let match = query.matchExpression else { return [] }
    let filter = (kinds ?? []).jsUnique()
    return try transaction.query { database in
      guard try RetrievalTables.exist(in: database) else { return [] }
      let search = RetrievalTables.loreSearch
      let kindFilter = filter.isEmpty ? "" : "AND l.kind IN (\(Array(repeating: "?", count: filter.count).joined(separator: ", ")))"
      var arguments: StatementArguments = [match, novel]
      arguments += StatementArguments(filter)
      arguments += [k]
      return try Row.fetchAll(
        database,
        sql: """
          SELECT l.kind, l.ref_key, l.text, -bm25(\(search)) AS score FROM \(search) JOIN \(RetrievalTables.lore) l ON l.id = \(search).rowid
          WHERE \(search) MATCH ? AND l.novel = ? \(kindFilter) ORDER BY score DESC, l.kind, l.ref_key LIMIT ?
          """,
        arguments: arguments
      ).map { RetrievalHit(text: $0["text"], score: $0["score"], origin: .lore(kind: $0["kind"], refKey: $0["ref_key"])) }
    }
  }
}

/// apps/novel-forge-server/src/common/isolated-chapters.ts:8-13, read from the records as they stand now: a chapter whose final canon or live draft head is
/// isolated, or either of which this version cannot read, is left out of prose results.
private struct ChapterIsolation {
  let novel: UUID
  private var known: [Int: Bool] = [:]

  init(novel: UUID) {
    self.novel = novel
  }

  mutating func isIsolated(_ chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    if let isolated = known[chapter] { return isolated }
    let isolated = try Self.reads(novel: novel, chapter: chapter, in: transaction)
    known[chapter] = isolated
    return isolated
  }

  private static func reads(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    guard let final = try? FinalChapterRecord.ref(novel: novel, chapter: chapter), let draft = try? DraftRecord.ref(novel: novel, chapter: chapter) else { return true }
    switch try FinalChapterRecord.read(final, in: transaction) {
    case .readable(let entry): if entry.record.canon.isolated { return true }
    case .unreadable: return true
    case .absent: break
    }
    switch try DraftRecord.readHead(draft, in: transaction) {
    case .readable(let entry): return !entry.isRemoved && entry.record.content.isolated
    case .unreadable: return true
    case .absent: return false
    }
  }
}
