import Foundation
import GRDB
import ShadowStore

/// This device's retrieval index, never synced. `nf_local_retrieval_source` has one row per record of the corpus with the record digest it last read,
/// stamped with the corpus version, and the hash of what it indexed (null when the record gives nothing to index); prose chunks and lore rows hang off it.
/// Each FTS5 table is external-content over its rows and kept equal to them by triggers, so every insert, update and delete of a row, the cleanup's
/// included, reaches the index. `nf_local_retrieval_vector` holds at most one embedding per prose or lore row with the model that made it (a null vector
/// marks a text that model could not embed); triggers drop it with its row or when the row changes, so a reused row id never inherits a vector.
enum RetrievalTables {
  static let source = "nf_local_retrieval_source"
  static let prose = "nf_local_retrieval_prose"
  static let proseSearch = "nf_local_retrieval_prose_fts"
  static let lore = "nf_local_retrieval_lore"
  static let loreSearch = "nf_local_retrieval_lore_fts"
  static let vector = "nf_local_retrieval_vector"

  static let all = [source, prose, proseSearch, lore, loreSearch]

  private static let definitions =
    [
      """
      CREATE TABLE IF NOT EXISTS nf_local_retrieval_source (
        id INTEGER PRIMARY KEY, novel BLOB NOT NULL, record_kind TEXT NOT NULL, record_key TEXT NOT NULL, digest TEXT NOT NULL, content TEXT,
        UNIQUE (record_kind, record_key)
      ) STRICT
      """,
      "CREATE INDEX IF NOT EXISTS nf_local_retrieval_source_novel ON nf_local_retrieval_source (novel)",
      """
      CREATE TABLE IF NOT EXISTS nf_local_retrieval_prose (
        id INTEGER PRIMARY KEY, source INTEGER NOT NULL, novel BLOB NOT NULL, chapter INTEGER NOT NULL, ordinal INTEGER NOT NULL, text TEXT NOT NULL,
        UNIQUE (source, ordinal)
      ) STRICT
      """,
      "CREATE INDEX IF NOT EXISTS nf_local_retrieval_prose_novel ON nf_local_retrieval_prose (novel, chapter)",
      """
      CREATE TABLE IF NOT EXISTS nf_local_retrieval_lore (
        id INTEGER PRIMARY KEY, source INTEGER NOT NULL UNIQUE, novel BLOB NOT NULL, kind TEXT NOT NULL, ref_key TEXT NOT NULL, text TEXT NOT NULL
      ) STRICT
      """,
      "CREATE INDEX IF NOT EXISTS nf_local_retrieval_lore_novel ON nf_local_retrieval_lore (novel, kind)",
      """
      CREATE TABLE IF NOT EXISTS nf_local_retrieval_vector (
        corpus TEXT NOT NULL CHECK (corpus IN ('prose', 'lore')), item INTEGER NOT NULL, novel BLOB NOT NULL, model TEXT NOT NULL, vector BLOB,
        PRIMARY KEY (corpus, item)
      ) STRICT
      """,
      "CREATE INDEX IF NOT EXISTS nf_local_retrieval_vector_novel ON nf_local_retrieval_vector (novel, model, corpus)",
    ] + searchDefinitions(proseSearch, over: prose) + searchDefinitions(loreSearch, over: lore)
    + vectorDefinitions(over: prose, corpus: .prose) + vectorDefinitions(over: lore, corpus: .lore)

  static func create(in database: Database) throws {
    for definition in definitions { try database.execute(sql: definition) }
  }

  static func exist(in database: Database) throws -> Bool {
    try all.allSatisfy { try database.tableExists($0) }
  }

  /// With its novel, so a deleted novel leaves no source, chunk or index entry behind.
  static func forget(novel: UUID, in database: Database) throws(StoreError) {
    do {
      for table in [vector, prose, lore, source] where try database.tableExists(table) {
        try database.execute(sql: "DELETE FROM \(table) WHERE novel = ?", arguments: [novel])
      }
    } catch {
      throw StoreError(projecting: error)
    }
  }

  static func removeRows(ofSource id: Int64, in database: Database) throws {
    try database.execute(sql: "DELETE FROM \(prose) WHERE source = ?", arguments: [id])
    try database.execute(sql: "DELETE FROM \(lore) WHERE source = ?", arguments: [id])
  }

  private static func vectorDefinitions(over table: String, corpus: RetrievalVectors.Corpus) -> [String] {
    [
      """
      CREATE TRIGGER IF NOT EXISTS \(table)_vector_deleted AFTER DELETE ON \(table) BEGIN
        DELETE FROM \(vector) WHERE corpus = '\(corpus.rawValue)' AND item = old.id;
      END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS \(table)_vector_updated AFTER UPDATE ON \(table) BEGIN
        DELETE FROM \(vector) WHERE corpus = '\(corpus.rawValue)' AND item = old.id;
      END
      """,
    ]
  }

  private static func searchDefinitions(_ search: String, over table: String) -> [String] {
    [
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS \(search) USING fts5(
        text, content='\(table)', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
      )
      """,
      """
      CREATE TRIGGER IF NOT EXISTS \(table)_inserted AFTER INSERT ON \(table) BEGIN
        INSERT INTO \(search) (rowid, text) VALUES (new.id, new.text);
      END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS \(table)_deleted AFTER DELETE ON \(table) BEGIN
        INSERT INTO \(search) (\(search), rowid, text) VALUES ('delete', old.id, old.text);
      END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS \(table)_updated AFTER UPDATE ON \(table) BEGIN
        INSERT INTO \(search) (\(search), rowid, text) VALUES ('delete', old.id, old.text);
        INSERT INTO \(search) (rowid, text) VALUES (new.id, new.text);
      END
      """,
    ]
  }
}
