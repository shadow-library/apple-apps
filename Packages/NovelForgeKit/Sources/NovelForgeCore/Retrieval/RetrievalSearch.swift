import Foundation
import GRDB
import ShadowStore

/// BM25 over the FTS5 tables; a hit's score is the negated `bm25()`, so higher is better and never below zero. Given a query vector (only once the novel is
/// fully embedded, `fusable`), the stored vectors of its model are ranked by cosine too, and when that leaves any candidate (after isolation or the kinds)
/// the two lists are fused by reciprocal rank, the hit's score becoming the fused one; otherwise the BM25 ranking stands alone, unchanged.
enum RetrievalSearch {
  /// How deep each list goes into the fusion: well past any k a caller asks for, where 1 / (60 + rank) no longer moves the order.
  static let fusionDepth = 50

  private struct ProseCandidate {
    let id: Int64
    let chapter: Int
    let ordinal: Int
    let score: Double

    static func precedes(_ first: Self, _ second: Self) -> Bool {
      (first.chapter, first.ordinal) < (second.chapter, second.ordinal)
    }
  }

  private struct LoreCandidate {
    let id: Int64
    let kind: String
    let refKey: String
    let score: Double

    static func precedes(_ first: Self, _ second: Self) -> Bool {
      (first.kind, first.refKey) < (second.kind, second.refKey)
    }
  }

  /// The query vector when no row of the novel, in either corpus, still waits for its model; nil otherwise. Fusing a partly embedded novel would rank every
  /// row not yet embedded (the newest chapters, or the whole novel after a model change) below almost any embedded one, and would mix fused and BM25 scores
  /// between the prose and lore of one search.
  static func fusable(_ vector: RetrievalQueryVector?, novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> RetrievalQueryVector? {
    guard let vector else { return nil }
    let complete = try transaction.query { database in
      try RetrievalVectors.isComplete(novel: novel, model: vector.model, dimension: vector.values.count, in: database)
    }
    return complete ? vector : nil
  }

  static func prose(
    novel: UUID, query: RetrievalQuery, k: Int, vector: RetrievalQueryVector? = nil, in transaction: ReadTransaction
  ) throws(StoreError) -> [RetrievalHit] {
    guard k > 0, let match = query.matchExpression else { return [] }
    let (lexical, semantic) = try transaction.query { database -> ([ProseCandidate], [ProseCandidate]) in
      guard try RetrievalTables.exist(in: database) else { return ([], []) }
      let search = RetrievalTables.proseSearch
      let lexical = try Row.fetchAll(
        database,
        sql: """
          SELECT p.id, p.chapter, p.ordinal, -bm25(\(search)) AS score FROM \(search) JOIN \(RetrievalTables.prose) p ON p.id = \(search).rowid
          WHERE \(search) MATCH ? AND p.novel = ? ORDER BY score DESC, p.chapter, p.ordinal
          """,
        arguments: [match, novel]
      ).map { ProseCandidate(id: $0["id"], chapter: $0["chapter"], ordinal: $0["ordinal"], score: $0["score"]) }
      guard let vector, try database.tableExists(RetrievalTables.vector) else { return (lexical, []) }
      let semantic = try RetrievalVectors.similarities(
        """
        SELECT p.id, p.chapter, p.ordinal, v.vector FROM \(RetrievalTables.vector) v JOIN \(RetrievalTables.prose) p ON p.id = v.item
        WHERE v.corpus = 'prose' AND v.novel = ? AND v.model = ? AND v.vector IS NOT NULL
        """,
        arguments: [novel, vector.model], to: vector, in: database
      ) { row in (id: row["id"] as Int64, chapter: row["chapter"] as Int, ordinal: row["ordinal"] as Int) }
      .map { ProseCandidate(id: $0.item.id, chapter: $0.item.chapter, ordinal: $0.item.ordinal, score: $0.score) }
      return (lexical, semantic.sorted { $0.score != $1.score ? $0.score > $1.score : ProseCandidate.precedes($0, $1) })
    }
    var isolation = ChapterIsolation(novel: novel)
    let depth = max(k, fusionDepth)
    let semanticKept = try visible(semantic, limit: depth, isolation: &isolation, in: transaction)
    let kept: [(item: ProseCandidate, score: Double)]
    if semanticKept.isEmpty {
      kept = try visible(lexical, limit: k, isolation: &isolation, in: transaction).map { ($0, $0.score) }
    } else {
      let lexicalKept = try visible(lexical, limit: depth, isolation: &isolation, in: transaction)
      kept = RetrievalFusion.fuse(lexical: lexicalKept, semantic: semanticKept, id: \.id, limit: k)
    }
    return try transaction.query { database in
      try kept.compactMap { row in
        try String.fetchOne(database, sql: "SELECT text FROM \(RetrievalTables.prose) WHERE id = ?", arguments: [row.item.id])
          .map { RetrievalHit(text: $0, score: row.score, origin: .prose(chapter: row.item.chapter)) }
      }
    }
  }

  /// An empty `kinds` filters nothing, as in the reference; any other list is bound value by value, so an unknown kind only matches nothing.
  static func lore(
    novel: UUID, query: RetrievalQuery, k: Int, kinds: [String]?, vector: RetrievalQueryVector? = nil, in transaction: ReadTransaction
  ) throws(StoreError) -> [RetrievalHit] {
    guard k > 0, let match = query.matchExpression else { return [] }
    let filter = (kinds ?? []).jsUnique()
    return try transaction.query { database in
      guard try RetrievalTables.exist(in: database) else { return [] }
      let search = RetrievalTables.loreSearch
      let kindFilter = filter.isEmpty ? "" : "AND l.kind IN (\(Array(repeating: "?", count: filter.count).joined(separator: ", ")))"
      let depth = max(k, fusionDepth)
      var lexicalArguments: StatementArguments = [match, novel]
      lexicalArguments += StatementArguments(filter)
      lexicalArguments += [depth]
      let lexical = try Row.fetchAll(
        database,
        sql: """
          SELECT l.id, l.kind, l.ref_key, -bm25(\(search)) AS score FROM \(search) JOIN \(RetrievalTables.lore) l ON l.id = \(search).rowid
          WHERE \(search) MATCH ? AND l.novel = ? \(kindFilter) ORDER BY score DESC, l.kind, l.ref_key LIMIT ?
          """,
        arguments: lexicalArguments
      ).map { LoreCandidate(id: $0["id"], kind: $0["kind"], refKey: $0["ref_key"], score: $0["score"]) }
      var semantic: [LoreCandidate] = []
      if let vector, try database.tableExists(RetrievalTables.vector) {
        var semanticArguments: StatementArguments = [novel, vector.model]
        semanticArguments += StatementArguments(filter)
        semantic = try RetrievalVectors.similarities(
          """
          SELECT l.id, l.kind, l.ref_key, v.vector FROM \(RetrievalTables.vector) v JOIN \(RetrievalTables.lore) l ON l.id = v.item
          WHERE v.corpus = 'lore' AND v.novel = ? AND v.model = ? AND v.vector IS NOT NULL \(kindFilter)
          """,
          arguments: semanticArguments, to: vector, in: database
        ) { row in (id: row["id"] as Int64, kind: row["kind"] as String, refKey: row["ref_key"] as String) }
        .map { LoreCandidate(id: $0.item.id, kind: $0.item.kind, refKey: $0.item.refKey, score: $0.score) }
        .sorted { $0.score != $1.score ? $0.score > $1.score : LoreCandidate.precedes($0, $1) }
      }
      let kept: [(item: LoreCandidate, score: Double)] =
        semantic.isEmpty
        ? lexical.prefix(k).map { ($0, $0.score) }
        : RetrievalFusion.fuse(lexical: lexical, semantic: Array(semantic.prefix(depth)), id: \.id, limit: k)
      return try kept.compactMap { row in
        try String.fetchOne(database, sql: "SELECT text FROM \(RetrievalTables.lore) WHERE id = ?", arguments: [row.item.id])
          .map { RetrievalHit(text: $0, score: row.score, origin: .lore(kind: row.item.kind, refKey: row.item.refKey)) }
      }
    }
  }

  /// The candidates, in order, whose chapter is not isolated now, until `limit` of them.
  private static func visible(
    _ candidates: [ProseCandidate], limit: Int, isolation: inout ChapterIsolation, in transaction: ReadTransaction
  ) throws(StoreError) -> [ProseCandidate] {
    var kept: [ProseCandidate] = []
    for candidate in candidates where kept.count < limit {
      if try !isolation.isIsolated(candidate.chapter, in: transaction) { kept.append(candidate) }
    }
    return kept
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
