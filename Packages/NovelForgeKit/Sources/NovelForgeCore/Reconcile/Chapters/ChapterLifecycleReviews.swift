import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// One readable chapter review, so a per-novel pass finds a chapter's latest judge review without decoding every review of the novel. `kind` is the stored raw
/// value, known or not; `draft` is nil for a review of finalized text (apps/novel-forge-server/src/database/schemas/review.ts:48).
struct ChapterReviewEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "nf_derived_chapter_review"

  let id: UUID
  let novel: UUID
  let chapter: Int
  let kind: String
  let draft: String?
  let clock: HLCTimestamp

  init(id: UUID, novel: UUID, chapter: Int, kind: String, draft: String?, clock: HLCTimestamp) {
    self.id = id
    self.novel = novel
    self.chapter = chapter
    self.kind = kind
    self.draft = draft
    self.clock = clock
  }

  init(row: Row) throws {
    let key = try row.decode(String.self, forColumn: "id")
    guard let id = UUID(uuidString: key), EntityKey(uuid: id).rawValue == key, let clock = HLCTimestamp(try row.decode(String.self, forColumn: "clock")) else {
      throw StoreError.corruptStore("a chapter review entry holds an invalid id or clock")
    }
    self.init(
      id: id, novel: try row.decode(UUID.self, forColumn: "novel"), chapter: try row.decode(Int.self, forColumn: "chapter"),
      kind: try row.decode(String.self, forColumn: "kind"), draft: try row.decode(String?.self, forColumn: "draft"), clock: clock)
  }

  var ref: EntityRef { ChapterReviewRecord.ref(id) }

  func encode(to container: inout PersistenceContainer) throws {
    container["id"] = ref.key.rawValue
    container["novel"] = novel
    container["chapter"] = chapter
    container["kind"] = kind
    container["draft"] = draft
    container["clock"] = clock.description
  }

  /// review-records.ts:154 orders by creation, then id; here by clock, then ref, so the latest is the last on every device.
  static func precedes(_ first: ChapterReviewEntry, _ second: ChapterReviewEntry) -> Bool {
    guard first.clock == second.clock else { return first.clock < second.clock }
    return first.ref < second.ref
  }
}

// One row per readable review; a review this version cannot read holds nothing, as an unreadable approval approves nothing, and leaves the latest readable one
// to gate.
struct ChapterReviewDerivation: Derivation {
  static let version = 1
  static let definition = """
    CREATE TABLE nf_derived_chapter_review (
      id TEXT PRIMARY KEY, novel BLOB NOT NULL, chapter INTEGER NOT NULL, kind TEXT NOT NULL, draft TEXT, clock TEXT NOT NULL
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_chapter_review_novel ON nf_derived_chapter_review (novel, kind, chapter);
    """

  var inputs: [DerivationInput<EntityRef>] {
    [.records([.chapterReview]) { [$0] }]
  }

  static func key(of output: ChapterReviewEntry) -> EntityRef { output.ref }

  static func request(for ref: EntityRef) -> QueryInterfaceRequest<ChapterReviewEntry> {
    ChapterReviewEntry.filter(Column("id") == ref.key.rawValue)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .chapterReview))
  }

  func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ChapterReviewEntry] {
    guard case .readable(let entry) = try ChapterReviewRecord.read(ref, in: context.records) else { return [] }
    let review = entry.record
    return [
      ChapterReviewEntry(
        id: review.id, novel: review.novel, chapter: review.chapter, kind: review.reviewKind.rawValue, draft: review.draftRevision, clock: entry.clock)
    ]
  }
}
