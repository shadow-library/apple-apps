import Accelerate
import Foundation
import GRDB
import ShadowStore

/// A query embedded by the novel's current model, scaled to unit length.
struct RetrievalQueryVector: Sendable, Equatable {
  let model: String
  let values: [Float]
}

/// The embeddings of the index's prose and lore rows. A vector is stored scaled to unit length as little-endian Float32 (`dimension` × 4 bytes), so a cosine
/// is one dot product; a blob of any other length is ignored when read and embedded again. Only vectors of the model asked for are ever read or compared.
enum RetrievalVectors {
  enum Corpus: String, Sendable, CaseIterable {
    case prose
    case lore
  }

  struct Pending: Sendable, Equatable {
    let corpus: Corpus
    let item: Int64
    let text: String
  }

  static let batchSize = 16
  static let sampleRows = 8
  static let sampleLength = 2000

  /// The model the novel's vectors were made by, read from the index's first entry for the novel; a pass drops every other model's rows, so there is one.
  static func storedModel(novel: UUID, in database: Database) throws -> String? {
    guard try database.tableExists(RetrievalTables.vector) else { return nil }
    return try String.fetchOne(database, sql: "SELECT model FROM \(RetrievalTables.vector) WHERE novel = ? LIMIT 1", arguments: [novel])
  }

  /// No row of either corpus still waits for `model`: each holds a usable vector or a failure mark of it.
  static func isComplete(novel: UUID, model: String, dimension: Int, in database: Database) throws -> Bool {
    try Corpus.allCases.allSatisfy { corpus in
      try pending(novel: novel, model: model, dimension: dimension, corpus: corpus, after: 0, limit: 1, in: database).isEmpty
    }
  }

  /// The opening of the novel's prose in chapter order, or of its lore when it has no prose yet: stable while later chapters are added, so the language
  /// read from it, and with it the model, changes only when the opening does.
  static func sample(novel: UUID, in database: Database) throws -> String {
    guard try RetrievalTables.exist(in: database) else { return "" }
    let queries = [
      "SELECT text FROM \(RetrievalTables.prose) WHERE novel = ? ORDER BY chapter, ordinal LIMIT ?",
      "SELECT text FROM \(RetrievalTables.lore) WHERE novel = ? ORDER BY kind, ref_key LIMIT ?",
    ]
    for sql in queries {
      let sample = String(try String.fetchAll(database, sql: sql, arguments: [novel, sampleRows]).joined(separator: "\n\n").prefix(sampleLength))
      if sample.contains(where: { !$0.isWhitespace }) { return sample }
    }
    return ""
  }

  /// Rows of one corpus after `item`, in id order, that hold no usable vector or failure mark of `model`. Paging by id ends every pass, whatever its writes do.
  static func pending(novel: UUID, model: String, dimension: Int, corpus: Corpus, after item: Int64, limit: Int, in database: Database) throws -> [Pending] {
    guard limit > 0, try RetrievalTables.exist(in: database) else { return [] }
    let table = rows(of: corpus)
    let fetched: [Row]
    if try database.tableExists(RetrievalTables.vector) {
      fetched = try Row.fetchAll(
        database,
        sql: """
          SELECT r.id, r.text FROM \(table) r LEFT JOIN \(RetrievalTables.vector) v ON v.corpus = ? AND v.item = r.id
          WHERE r.novel = ? AND r.id > ? AND (v.item IS NULL OR v.model != ? OR length(v.vector) != ?) ORDER BY r.id LIMIT ?
          """,
        arguments: [corpus.rawValue, novel, item, model, dimension * 4, limit])
    } else {
      fetched = try Row.fetchAll(
        database, sql: "SELECT id, text FROM \(table) WHERE novel = ? AND id > ? ORDER BY id LIMIT ?", arguments: [novel, item, limit])
    }
    return fetched.map { Pending(corpus: corpus, item: $0["id"], text: $0["text"]) }
  }

  /// Drops the novel's vectors of any other model, then records each row's vector, or a failure mark when it has none, if the row still holds the text that
  /// was embedded; a usable vector of `model` that a concurrent pass stored first is kept. Returns how many rows got a vector and how many a failure mark.
  static func store(
    _ batch: [Pending], vectors: [[Float]?], novel: UUID, model: String, dimension: Int, in database: Database
  ) throws -> (embedded: Int, failed: Int) {
    try RetrievalTables.create(in: database)
    try database.execute(sql: "DELETE FROM \(RetrievalTables.vector) WHERE novel = ? AND model != ?", arguments: [novel, model])
    var embedded = 0
    var failed = 0
    for (row, vector) in zip(batch, vectors) {
      let current = try Bool.fetchOne(
        database, sql: "SELECT EXISTS (SELECT 1 FROM \(rows(of: row.corpus)) WHERE id = ? AND novel = ? AND text = ?)", arguments: [row.item, novel, row.text])
      guard current == true else { continue }
      let blob = vector.flatMap { unit($0, dimension: dimension) }.map(encode)
      try database.execute(
        sql: """
          INSERT INTO \(RetrievalTables.vector) (corpus, item, novel, model, vector) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (corpus, item) DO UPDATE SET novel = excluded.novel, model = excluded.model, vector = excluded.vector
          WHERE (\(RetrievalTables.vector).vector IS NULL AND excluded.vector IS NOT NULL) OR length(\(RetrievalTables.vector).vector) != ?
          """,
        arguments: [row.corpus.rawValue, row.item, novel, model, blob, dimension * 4])
      guard database.changesCount > 0 else { continue }
      if blob == nil { failed += 1 } else { embedded += 1 }
    }
    return (embedded, failed)
  }

  /// Every stored vector of `query.model` that the statement selects (as its `vector` column), scored by cosine with the query; rows read through `item`.
  static func similarities<Item>(
    _ sql: String, arguments: StatementArguments, to query: RetrievalQueryVector, in database: Database, item: (Row) -> Item
  ) throws -> [(item: Item, score: Double)] {
    var buffer = [Float](repeating: 0, count: query.values.count)
    var scored: [(item: Item, score: Double)] = []
    let cursor = try Row.fetchCursor(database, sql: sql, arguments: arguments)
    while let row = try cursor.next() {
      guard let blob = row["vector"] as Data?, decode(blob, into: &buffer) else { continue }
      let score = Double(vDSP.dot(buffer, query.values))
      if score.isFinite { scored.append((item(row), score)) }
    }
    return scored
  }

  /// Nil for a vector that cannot be compared: another length, a non-finite component or no direction at all.
  static func unit(_ values: [Float], dimension: Int) -> [Float]? {
    guard dimension > 0, values.count == dimension, values.allSatisfy(\.isFinite) else { return nil }
    let norm = vDSP.sumOfSquares(values).squareRoot()
    guard norm.isFinite, norm > 0 else { return nil }
    return vDSP.divide(values, norm)
  }

  static func encode(_ values: [Float]) -> Data {
    var data = Data(capacity: values.count * MemoryLayout<UInt32>.size)
    for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    return data
  }

  static func decode(_ blob: Data, into buffer: inout [Float]) -> Bool {
    let width = MemoryLayout<UInt32>.size
    guard blob.count == buffer.count * width else { return false }
    blob.withUnsafeBytes { raw in
      for index in buffer.indices { buffer[index] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * width, as: UInt32.self))) }
    }
    return true
  }

  private static func rows(of corpus: Corpus) -> String {
    switch corpus {
    case .prose: RetrievalTables.prose
    case .lore: RetrievalTables.lore
    }
  }
}
