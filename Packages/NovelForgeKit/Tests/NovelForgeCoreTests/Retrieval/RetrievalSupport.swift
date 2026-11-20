import Foundation
import GRDB
import ShadowCore
import ShadowStore

@testable import NovelForgeCore

struct RetrievalWorld {
  static let novel = UUID(uuidString: "6f0c4d1e-0000-4000-8000-0000000000e1") ?? UUID()
  static let otherNovel = UUID(uuidString: "6f0c4d1e-0000-4000-8000-0000000000e2") ?? UUID()

  let store: VaultStore
  let embedders: (any EmbedderProvider)?
  let novel = Self.novel

  init(store: VaultStore? = nil, embedder: FakeEmbedder? = nil) throws {
    self.store = try store ?? NovelForgeStore.openInMemory()
    self.embedders = embedder.map { FakeEmbedders(embedder: $0) }
  }

  var retrieval: NovelRetrieval { NovelRetrieval(store: store, embedders: embedders) }

  func finalize(_ chapter: Int, _ body: String, isolated: Bool = false, novel: UUID = Self.novel) async throws {
    _ = try await store.write { transaction in
      try FinalChapterRecord(novel: novel, chapter: chapter, canon: Canon(body: body, isolated: isolated)).finalize(in: &transaction)
    }
  }

  func amend(_ chapter: Int, _ body: String) async throws {
    let ref = try FinalChapterRecord.ref(novel: novel, chapter: chapter)
    _ = try await store.write { transaction in try FinalChapterRecord.amend(ref, FinalChapterText(body: body), in: &transaction) }
  }

  func entity(_ key: String, name: String, notes: String? = nil, body: String? = nil, novel: UUID = Self.novel) async throws {
    _ = try await store.write { transaction in
      try EntityRecord(novel: novel, entity: key, type: .known(.character), name: name, notes: notes, body: body).create(in: &transaction)
    }
  }

  func editEntity(_ key: String, _ edit: EntityEdit) async throws {
    let novel = novel
    _ = try await store.write { transaction in try EntityRecord.edit(novel: novel, entity: key, edit, in: &transaction) }
  }

  func removeEntity(_ key: String) async throws {
    let novel = novel
    _ = try await store.write { transaction in try EntityRecord.remove(novel: novel, entity: key, in: &transaction) }
  }

  func page(_ section: BiblePageSection, _ slug: String, _ body: String?) async throws {
    let novel = novel
    _ = try await store.write { transaction in
      let ref = PageRecord.ref(novel: novel, section: section, slug: slug)
      if try transaction.state(of: ref, scope: .vault) == nil {
        _ = try PageRecord(novel: novel, section: section, slug: slug, content: PageContent(body: body)).create(in: &transaction)
      } else {
        _ = try PageRecord.revise(novel: novel, section: section, slug: slug, PageContent(body: body), in: &transaction)
      }
    }
  }

  func removePage(_ section: BiblePageSection, _ slug: String) async throws {
    let novel = novel
    _ = try await store.write { transaction in try PageRecord.remove(novel: novel, section: section, slug: slug, in: &transaction) }
  }

  func draft(_ chapter: Int, isolated: Bool) async throws {
    let novel = novel
    _ = try await store.write { transaction in
      let ref = try DraftRecord.ref(novel: novel, chapter: chapter)
      let content = DraftContent(body: "draft of \(chapter)", source: .known(.generated), isolated: isolated)
      if try transaction.state(of: ref, scope: .vault) == nil {
        _ = try DraftRecord(novel: novel, chapter: chapter, content: content).create(in: &transaction)
      } else {
        _ = try DraftRecord.revise(ref, content, in: &transaction)
      }
    }
  }

  func proseChapters(_ query: String, k: Int = NovelRetrieval.defaultProseK) async throws -> [Int] {
    try await retrieval.searchProse(novel: novel, query: query, k: k).compactMap { hit in
      guard case .prose(let chapter) = hit.origin else { return nil }
      return chapter
    }
  }

  func loreKeys(_ query: String, kinds: [String]? = nil) async throws -> [String] {
    try await retrieval.searchLore(novel: novel, query: query, kinds: kinds).compactMap { hit in
      guard case .lore(let kind, let refKey) = hit.origin else { return nil }
      return "\(kind):\(refKey)"
    }
  }

  /// Every row of the index without its row ids, which differ between an index caught up step by step and one built at once.
  func dump() async throws -> [String] {
    try await store.read { transaction in
      let database = transaction.database
      guard try RetrievalTables.exist(in: database) else { return [] }
      let sources = try Row.fetchAll(database, sql: "SELECT novel, record_kind, record_key, digest, content FROM \(RetrievalTables.source)").map { "source \($0)" }
      let prose = try Row.fetchAll(
        database,
        sql: """
          SELECT s.record_key, p.novel, p.chapter, p.ordinal, p.text FROM \(RetrievalTables.prose) p JOIN \(RetrievalTables.source) s ON s.id = p.source
          """
      ).map { "prose \($0)" }
      let lore = try Row.fetchAll(
        database,
        sql: "SELECT s.record_key, l.novel, l.kind, l.ref_key, l.text FROM \(RetrievalTables.lore) l JOIN \(RetrievalTables.source) s ON s.id = l.source"
      ).map { "lore \($0)" }
      guard try database.tableExists(RetrievalTables.vector) else { return (sources + prose + lore).sorted() }
      let vectors = try Row.fetchAll(
        database,
        sql: """
          SELECT v.corpus, s.record_key, p.ordinal, v.novel, v.model, hex(v.vector) AS vector FROM \(RetrievalTables.vector) v
          JOIN \(RetrievalTables.prose) p ON v.corpus = 'prose' AND p.id = v.item JOIN \(RetrievalTables.source) s ON s.id = p.source
          UNION ALL
          SELECT v.corpus, s.record_key, NULL, v.novel, v.model, hex(v.vector) FROM \(RetrievalTables.vector) v
          JOIN \(RetrievalTables.lore) l ON v.corpus = 'lore' AND l.id = v.item JOIN \(RetrievalTables.source) s ON s.id = l.source
          """
      ).map { "vector \($0)" }
      return (sources + prose + lore + vectors).sorted()
    }
  }

  func rowCounts() async throws -> [String: Int] {
    try await store.read { transaction in
      let database = transaction.database
      var counts: [String: Int] = [:]
      for table in [RetrievalTables.source, RetrievalTables.prose, RetrievalTables.lore] where try database.tableExists(table) {
        counts[table] = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
      }
      return counts
    }
  }

  /// FTS5's own check that each search table holds exactly the entries of its rows; it throws `SQLITE_CORRUPT_VTAB` when they drift.
  func checkSearchIntegrity() async throws {
    try await store.write { transaction in
      for search in [RetrievalTables.proseSearch, RetrievalTables.loreSearch] where try transaction.database.tableExists(search) {
        try transaction.database.execute(sql: "INSERT INTO \(search) (\(search), rank) VALUES ('integrity-check', 1)")
      }
    }
  }

  /// Every vector row of every novel: whose row it is, which model made it and how many bytes it holds (nil for a failure mark).
  func vectors() async throws -> [StoredVector] {
    try await store.read { transaction in
      let database = transaction.database
      guard try database.tableExists(RetrievalTables.vector) else { return [] }
      return try Row.fetchAll(database, sql: "SELECT corpus, item, novel, model, vector FROM \(RetrievalTables.vector) ORDER BY corpus, item").map { row in
        StoredVector(corpus: row["corpus"], item: row["item"], novel: row["novel"], model: row["model"], vector: row["vector"])
      }
    }
  }

  /// Rows of the index that hold no vector row at all.
  func unvectoredRows() async throws -> Int {
    try await store.read { transaction in
      let database = transaction.database
      guard try RetrievalTables.exist(in: database), try database.tableExists(RetrievalTables.vector) else { return 0 }
      return try Int.fetchOne(
        database,
        sql: """
          SELECT (SELECT COUNT(*) FROM \(RetrievalTables.prose) p WHERE NOT EXISTS (
            SELECT 1 FROM \(RetrievalTables.vector) v WHERE v.corpus = 'prose' AND v.item = p.id))
          + (SELECT COUNT(*) FROM \(RetrievalTables.lore) l WHERE NOT EXISTS (
            SELECT 1 FROM \(RetrievalTables.vector) v WHERE v.corpus = 'lore' AND v.item = l.id))
          """) ?? 0
    }
  }
}

struct StoredVector: Equatable {
  let corpus: String
  let item: Int64
  let novel: UUID
  let model: String
  let vector: Data?
}
