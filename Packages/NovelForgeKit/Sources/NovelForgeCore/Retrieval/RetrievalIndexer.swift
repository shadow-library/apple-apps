import Foundation
import GRDB
import ShadowStore

/// Brings the index level with the records, whichever device wrote them: a record whose digest in the record index differs from the one its source last read
/// is read again, and only a changed text is re-chunked. Each source is replaced inside one transaction, and every batch re-reads what it changes there, so an
/// interrupted, repeated or concurrent catch-up leaves each source either as it was or as it is now.
enum RetrievalIndexer {
  static let batchSize = 16

  private struct StoredSource {
    let id: Int64
    let digest: String
    let content: String?
  }

  /// The records to read again, sorted: the novel's corpus records whose digest moved and the sources whose record left the corpus.
  static func pending(novel: UUID, version: Int = RetrievalCorpus.version, in transaction: ReadTransaction) throws(RetrievalError) -> [EntityRef] {
    try requireRecordIndex(novel: novel, in: transaction)
    do {
      return try transaction.query { database in
        let current = try currentDigests(novel: novel, version: version, in: database)
        let stored = try storedDigests(novel: novel, in: database)
        let changed = current.filter { stored[$0.key] != $0.value }.keys
        let vanished = stored.keys.filter { current[$0] == nil }
        return (Array(changed) + vanished).sorted()
      }
    } catch {
      throw .store(error)
    }
  }

  /// Checks the record index again in the batch's own transaction: a fault that appeared since `pending` would make missing rows read as records that left.
  static func refresh(_ refs: [EntityRef], novel: UUID, version: Int = RetrievalCorpus.version, in database: Database) throws(RetrievalError) -> RetrievalCatchUp {
    var outcome = RetrievalCatchUp()
    let records = ReadTransaction(database: database, registry: NovelForgeSchema.registry)
    try requireRecordIndex(novel: novel, in: records)
    do {
      try RetrievalTables.create(in: database)
      for ref in refs { outcome.count(try refresh(ref, novel: novel, version: version, records: records, in: database)) }
    } catch {
      throw .store(StoreError(projecting: error))
    }
    return outcome
  }

  private static func requireRecordIndex(novel: UUID, in transaction: ReadTransaction) throws(RetrievalError) {
    let faults: [ReadFault]
    do {
      faults = try ReadFaults(novel: novel, reading: [IndexedRecord.databaseTableName], in: transaction).blocking([IndexedRecord.databaseTableName])
    } catch {
      throw .store(error)
    }
    guard faults.isEmpty else { throw .indexUnavailable(faults) }
  }

  private static func refresh(_ ref: EntityRef, novel: UUID, version: Int, records: ReadTransaction, in database: Database) throws -> RetrievalCatchUp.Change? {
    let stored = try storedSource(ref, in: database)
    guard let current = try RecordIndexDerivation.request(for: ref).fetchOne(database), current.novel == novel, current.status == .live,
      RetrievalCorpus.kinds.contains(current.kind)
    else {
      guard let stored else { return nil }
      try RetrievalTables.removeRows(ofSource: stored.id, in: database)
      try database.execute(sql: "DELETE FROM \(RetrievalTables.source) WHERE id = ?", arguments: [stored.id])
      return stored.content == nil ? nil : .removed
    }
    let digest = RetrievalCorpus.stamp(current.digest, version: version)
    guard stored?.digest != digest else { return nil }
    let content = try RetrievalCorpus.content(of: ref, in: records)
    let hash = content.map { RetrievalCorpus.hash($0, version: version) }
    if let stored, stored.content == hash {
      try database.execute(sql: "UPDATE \(RetrievalTables.source) SET digest = ? WHERE id = ?", arguments: [digest, stored.id])
      return .confirmed
    }
    let id = try replaceSource(ref, novel: novel, digest: digest, hash: hash, stored: stored, in: database)
    switch content {
    case .prose(let chapter, let body):
      for (ordinal, text) in RetrievalChunker.chunk(body).enumerated() {
        try database.execute(
          sql: "INSERT INTO \(RetrievalTables.prose) (source, novel, chapter, ordinal, text) VALUES (?, ?, ?, ?, ?)",
          arguments: [id, novel, chapter, ordinal, text])
      }
    case .lore(let kind, let refKey, let text):
      try database.execute(
        sql: "INSERT INTO \(RetrievalTables.lore) (source, novel, kind, ref_key, text) VALUES (?, ?, ?, ?, ?)", arguments: [id, novel, kind.rawValue, refKey, text])
    case nil:
      break
    }
    switch (stored?.content, hash) {
    case (nil, nil): return .confirmed
    case (nil, _): return .added
    case (_, nil): return .removed
    default: return .updated
    }
  }

  private static func replaceSource(_ ref: EntityRef, novel: UUID, digest: String, hash: String?, stored: StoredSource?, in database: Database) throws -> Int64 {
    guard let stored else {
      try database.execute(
        sql: "INSERT INTO \(RetrievalTables.source) (novel, record_kind, record_key, digest, content) VALUES (?, ?, ?, ?, ?)",
        arguments: [novel, ref.kind.rawValue, ref.key.rawValue, digest, hash])
      return database.lastInsertedRowID
    }
    try RetrievalTables.removeRows(ofSource: stored.id, in: database)
    try database.execute(sql: "UPDATE \(RetrievalTables.source) SET digest = ?, content = ? WHERE id = ?", arguments: [digest, hash, stored.id])
    return stored.id
  }

  private static func currentDigests(novel: UUID, version: Int, in database: Database) throws -> [EntityRef: String] {
    let rows = try IndexedRecord.filter(Column("novel") == novel && RetrievalCorpus.kinds.contains(Column("kind")) && Column("status") == IndexedStatus.live)
      .fetchAll(database)
    return Dictionary(rows.map { ($0.ref, RetrievalCorpus.stamp($0.digest, version: version)) }) { first, _ in first }
  }

  private static func storedDigests(novel: UUID, in database: Database) throws -> [EntityRef: String] {
    guard try database.tableExists(RetrievalTables.source) else { return [:] }
    let rows = try Row.fetchAll(database, sql: "SELECT record_kind, record_key, digest FROM \(RetrievalTables.source) WHERE novel = ?", arguments: [novel])
    var digests: [EntityRef: String] = [:]
    for row in rows {
      guard let kind = EntityKind(row["record_kind"] as String), let key = EntityKey(row["record_key"] as String) else { continue }
      digests[EntityRef(kind: kind, key: key)] = row["digest"]
    }
    return digests
  }

  private static func storedSource(_ ref: EntityRef, in database: Database) throws -> StoredSource? {
    try Row.fetchOne(
      database, sql: "SELECT id, digest, content FROM \(RetrievalTables.source) WHERE record_kind = ? AND record_key = ?", arguments: [ref.kind.rawValue, ref.key.rawValue]
    ).map { StoredSource(id: $0["id"], digest: $0["digest"], content: $0["content"]) }
  }
}
