import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// One readable approval with the fingerprints it recorded, so a per-novel pass reads approvals as rows. `kind` is the stored raw value, known or not.
struct ChapterApprovalEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "nf_derived_chapter_approval"

  let id: UUID
  let novel: UUID
  let chapter: Int
  let kind: String
  let draft: String
  let terms: String?
  let upstream: String?
  let clock: HLCTimestamp

  init(id: UUID, novel: UUID, chapter: Int, kind: String, draft: String, terms: String?, upstream: String?, clock: HLCTimestamp) {
    self.id = id
    self.novel = novel
    self.chapter = chapter
    self.kind = kind
    self.draft = draft
    self.terms = terms
    self.upstream = upstream
    self.clock = clock
  }

  init(row: Row) throws {
    guard let id = ApprovalColumn.decode(try row.decode(String.self, forColumn: "id")), let clock = HLCTimestamp(try row.decode(String.self, forColumn: "clock")) else {
      throw StoreError.corruptStore("a chapter approval entry holds an invalid id or clock")
    }
    self.init(
      id: id, novel: try row.decode(UUID.self, forColumn: "novel"), chapter: try row.decode(Int.self, forColumn: "chapter"),
      kind: try row.decode(String.self, forColumn: "kind"), draft: try row.decode(String.self, forColumn: "draft"), terms: try row.decode(String?.self, forColumn: "terms"),
      upstream: try row.decode(String?.self, forColumn: "upstream"), clock: clock)
  }

  var ref: EntityRef { ApprovalRecord.ref(id) }

  var approvalKind: ApprovalKind? { StoredEnum<ApprovalKind>(rawValue: kind).known }

  func encode(to container: inout PersistenceContainer) throws {
    container["id"] = ApprovalColumn.encode(id)
    container["novel"] = novel
    container["chapter"] = chapter
    container["kind"] = kind
    container["draft"] = draft
    container["terms"] = terms
    container["upstream"] = upstream
    container["clock"] = clock.description
  }

  /// Chronological, so the latest is the last: clock, then id (apps/novel-forge-server's single approved revision becomes the latest approval item).
  static func precedes(_ first: ChapterApprovalEntry, _ second: ChapterApprovalEntry) -> Bool {
    guard first.clock == second.clock else { return first.clock < second.clock }
    return first.ref < second.ref
  }
}

/// How every derived table stores an approval's id: as the key of its entity.
enum ApprovalColumn {
  static func encode(_ id: UUID) -> String { ApprovalRecord.ref(id).key.rawValue }

  static func decode(_ text: String) -> UUID? {
    guard let id = UUID(uuidString: text), encode(id) == text else { return nil }
    return id
  }
}

// One row per readable approval; an approval this version cannot read approves nothing.
struct ChapterApprovalDerivation: Derivation {
  static let version = 1
  static let definition = """
    CREATE TABLE nf_derived_chapter_approval (
      id TEXT PRIMARY KEY, novel BLOB NOT NULL, chapter INTEGER NOT NULL, kind TEXT NOT NULL, draft TEXT NOT NULL, terms TEXT, upstream TEXT, clock TEXT NOT NULL
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_chapter_approval_novel ON nf_derived_chapter_approval (novel, chapter);
    """

  var inputs: [DerivationInput<EntityRef>] {
    [.records([.approval]) { [$0] }]
  }

  static func key(of output: ChapterApprovalEntry) -> EntityRef { output.ref }

  static func request(for ref: EntityRef) -> QueryInterfaceRequest<ChapterApprovalEntry> {
    ChapterApprovalEntry.filter(Column("id") == ref.key.rawValue)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .approval))
  }

  func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ChapterApprovalEntry] {
    guard case .readable(let entry) = try ApprovalRecord.read(ref, in: context.records) else { return [] }
    let record = entry.record
    return [
      ChapterApprovalEntry(
        id: record.id, novel: record.novel, chapter: record.chapter, kind: record.approvalKind.rawValue, draft: record.draftRevision, terms: record.planTermsDigest,
        upstream: record.upstreamDigest, clock: entry.clock)
    ]
  }
}
