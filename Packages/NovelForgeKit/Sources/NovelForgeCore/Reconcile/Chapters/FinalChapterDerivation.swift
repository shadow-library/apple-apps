import Foundation
import GRDB
import ShadowCore
import ShadowStore

public struct FinalChapterEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_final_chapter"

  public let key: EntityKey
  public let novel: UUID
  public let chapter: Int
  public let isReadable: Bool
  /// `FinalChapterRecord.digest` of the stored canon, readable or not; nil when the canon member is missing.
  public let canonDigest: String?
  /// The canon's `draft_revision`, the revision the chapter rests on for the chapters after it.
  public let draftRevision: String?
  /// `Canon.disclosed` as JSON text, decoded only by the derivation that reads it (`DisclosedColumn.decode`); nil when the canon recorded none or cannot be read.
  let disclosed: String?
  /// When the canon that stands was written (its first-writer-wins clock).
  public let canonClock: HLCTimestamp?
  /// The approval the canon names (`Canon.approval`), when it names one this version can read.
  public let approval: UUID?

  init(
    key: EntityKey, novel: UUID, chapter: Int, isReadable: Bool, canonDigest: String? = nil, draftRevision: String? = nil, disclosed: String? = nil,
    canonClock: HLCTimestamp? = nil, approval: UUID? = nil
  ) {
    self.key = key
    self.novel = novel
    self.chapter = chapter
    self.isReadable = isReadable
    self.canonDigest = canonDigest
    self.draftRevision = draftRevision
    self.disclosed = disclosed
    self.canonClock = canonClock
    self.approval = approval
  }

  public init(row: Row) throws {
    guard let key = EntityKey(try row.decode(String.self, forColumn: "key")) else { throw StoreError.corruptStore("a final chapter entry holds an invalid key") }
    self.init(
      key: key, novel: try row.decode(UUID.self, forColumn: "novel"), chapter: try row.decode(Int.self, forColumn: "chapter"),
      isReadable: try row.decode(Bool.self, forColumn: "readable"), canonDigest: try row.decode(String?.self, forColumn: "canon"),
      draftRevision: try row.decode(String?.self, forColumn: "draft"), disclosed: try row.decode(String?.self, forColumn: "disclosed"),
      canonClock: try row.decode(String?.self, forColumn: "canon_clock").flatMap(HLCTimestamp.init),
      approval: try row.decode(String?.self, forColumn: "approval").flatMap(ApprovalColumn.decode))
  }

  public var ref: EntityRef { EntityRef(kind: NovelForgeKind.finalChapter.entityKind, key: key) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["key"] = key.rawValue
    container["novel"] = novel
    container["chapter"] = chapter
    container["readable"] = isReadable
    container["canon"] = canonDigest
    container["draft"] = draftRevision
    container["disclosed"] = disclosed
    container["canon_clock"] = canonClock?.description
    container["approval"] = approval.map(ApprovalColumn.encode)
  }
}

// A chapter is final when its canon exists, so a canon this version cannot read still counts, marked unreadable.
public struct FinalChapterDerivation: Derivation {
  public static let version = 3
  public static let definition = """
    CREATE TABLE nf_derived_final_chapter (
      key TEXT PRIMARY KEY, novel BLOB NOT NULL, chapter INTEGER NOT NULL, readable INTEGER NOT NULL, canon TEXT, draft TEXT, disclosed TEXT, canon_clock TEXT, approval TEXT
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_final_chapter_novel ON nf_derived_final_chapter (novel, chapter);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.records([.finalChapter]) { [$0] }]
  }

  public static func key(of output: FinalChapterEntry) -> EntityRef {
    output.ref
  }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<FinalChapterEntry> {
    FinalChapterEntry.filter(Column("key") == ref.key.rawValue)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .finalChapter))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [FinalChapterEntry] {
    let state = try context.records.state(of: ref, scope: .vault)
    var canon: FieldState?
    if case .revisioned(let revisioned)? = state { canon = revisioned[field: FinalChapterField.canon.rawValue] }
    let stored = canon?.value
    let draft = stored?.objectValue?[FinalChapterCanonMember.draftRevision.rawValue]?.stringValue
    let approval = stored?.objectValue?[FinalChapterCanonMember.approval.rawValue].flatMap(UUID.init(json:))
    switch FinalChapterRecord.reading(state, of: ref) {
    case .absent:
      return []
    case .readable(let entry):
      return [
        FinalChapterEntry(
          key: ref.key, novel: entry.record.novel, chapter: entry.record.chapter, isReadable: true, canonDigest: entry.record.canonDigest, draftRevision: draft,
          disclosed: try entry.record.canon.disclosed.map(DisclosedColumn.encode), canonClock: canon?.clock, approval: approval)
      ]
    case .unreadable:
      guard let state, let key = try? NovelForgeKey(reading: state, of: ref), case .finalChapter(let chapter) = key.components else { return [] }
      return [
        FinalChapterEntry(
          key: ref.key, novel: key.novel, chapter: chapter, isReadable: false, canonDigest: stored.map(FinalChapterRecord.digest), draftRevision: draft,
          canonClock: canon?.clock, approval: approval)
      ]
    }
  }
}

/// The recorded set as JSON text, so a stored row always compares by its bytes and a fetch never decodes it.
enum DisclosedColumn {
  static func encode(_ keys: [String]) throws(StoreError) -> String {
    String(decoding: try sortedJSON(keys), as: UTF8.self)
  }

  static func decode(_ text: String) throws(StoreError) -> [String] {
    do {
      return try JSONDecoder().decode([String].self, from: Data(text.utf8))
    } catch {
      throw .corruptStore("a final chapter entry holds an unreadable disclosed list")
    }
  }
}
