import CryptoKit
import Foundation
import GRDB
import ShadowCore
import ShadowStore

public enum IndexedStatus: String, Sendable, DatabaseValueConvertible {
  case live
  case removed
  case unreadable
}

/// `digest` changes with every change to the entity's merged state, so a per-novel aggregate subscribes here and filters by kind.
public struct IndexedRecord: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_record"

  public let kind: NovelForgeKind
  public let key: EntityKey
  public let novel: UUID?
  public let status: IndexedStatus
  public let digest: String

  init(kind: NovelForgeKind, key: EntityKey, novel: UUID?, status: IndexedStatus, digest: String) {
    self.kind = kind
    self.key = key
    self.novel = novel
    self.status = status
    self.digest = digest
  }

  public init(row: Row) throws {
    guard let key = EntityKey(try row.decode(String.self, forColumn: "key")) else { throw StoreError.corruptStore("an indexed record holds an invalid key") }
    self.init(
      kind: try row.decode(NovelForgeKind.self, forColumn: "kind"), key: key, novel: try row.decode(UUID?.self, forColumn: "novel"),
      status: try row.decode(IndexedStatus.self, forColumn: "status"), digest: try row.decode(String.self, forColumn: "digest"))
  }

  public var ref: EntityRef { EntityRef(kind: kind.entityKind, key: key) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["kind"] = kind
    container["key"] = key.rawValue
    container["novel"] = novel
    container["status"] = status
    container["digest"] = digest
  }
}

public enum ProjectionDerivations {
  public static let all: [any Derivation] = [RecordIndexDerivation()]
}

public struct RecordIndexDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_record (
      kind TEXT NOT NULL, key TEXT NOT NULL, novel BLOB, status TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY (kind, key)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_record_novel ON nf_derived_record (novel, kind);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.records(NovelForgeKind.allCases) { [$0] }]
  }

  public static func key(of output: IndexedRecord) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<IndexedRecord> {
    IndexedRecord.filter(Column("kind") == ref.kind.rawValue && Column("key") == ref.key.rawValue)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    var refs = Set<EntityRef>()
    for kind in NovelForgeKind.allCases { refs.formUnion(try context.refs(of: kind)) }
    return refs
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [IndexedRecord] {
    guard let kind = NovelForgeKind(ref.kind), let state = try context.records.state(of: ref, scope: .vault) else { return [] }
    guard let (novel, status) = Self.classify(kind, ref, state) else { return [] }
    return [IndexedRecord(kind: kind, key: ref.key, novel: novel, status: status, digest: Self.digest(of: state))]
  }

  static func digest(of state: EntityState) -> String {
    let bytes = CanonicalJSON.encode(canonical(state))
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func canonical(_ state: EntityState) -> JSONValue {
    switch state {
    case .record(let record):
      ["fields": fields(record.fields)]
    case .appended(let appended):
      ["clock": .string(appended.clock.description), "item": .object(appended.item)]
    case .revisioned(let revisioned):
      // The store accepts a revision only under the hash of its item, so its id stands for its body.
      [
        "fields": fields(revisioned.fields), "head": revisioned.head.map(field) ?? .null, "marks": fields(revisioned.marks),
        "revisions": .array(sorted(revisioned.revisions).map { id, _ in .string(id.value) }),
      ]
    case .purged(let purged):
      ["purged": .string(purged.clock.description)]
    }
  }

  private static func fields(_ fields: [ExactString: FieldState]) -> JSONValue {
    .array(sorted(fields).map { name, state in ["name": .string(name.value), "field": field(state)] })
  }

  private static func field(_ state: FieldState) -> JSONValue {
    ["clock": .string(state.clock.description), "value": state.value]
  }

  private static func sorted<Value>(_ members: [ExactString: Value]) -> [(key: ExactString, value: Value)] {
    members.sorted { $0.key.value.utf8.lexicographicallyPrecedes($1.key.value.utf8) }
  }

  private static func classify(_ kind: NovelForgeKind, _ ref: EntityRef, _ state: EntityState) -> (UUID?, IndexedStatus)? {
    switch kind {
    case .novel: kept(NovelRecord.self, ref, state)
    case .volume: kept(VolumeRecord.self, ref, state)
    case .milestone: kept(MilestoneRecord.self, ref, state)
    case .thread: kept(ThreadRecord.self, ref, state)
    case .mystery: kept(MysteryRecord.self, ref, state)
    case .secret: kept(SecretRecord.self, ref, state)
    case .entity: kept(EntityRecord.self, ref, state)
    case .characterKnowledge: kept(CharacterKnowledgeRecord.self, ref, state)
    case .page: kept(PageRecord.self, ref, state)
    case .chapterPlan: kept(ChapterPlanRecord.self, ref, state)
    case .draft: kept(DraftRecord.self, ref, state)
    case .approval: appended(ApprovalRecord.self, ref, state)
    case .finalChapter: kept(FinalChapterRecord.self, ref, state)
    case .notebookEntry: appended(NotebookEntryRecord.self, ref, state)
    case .notebookWithdrawal: appended(NotebookWithdrawalRecord.self, ref, state)
    case .authorNotes: kept(AuthorNotesRecord.self, ref, state)
    }
  }

  private static func kept<Record: NovelForgeRecord>(_: Record.Type, _ ref: EntityRef, _ state: EntityState) -> (UUID?, IndexedStatus)? {
    switch Record.reading(state, of: ref) {
    case .absent: nil
    case .readable(let entry): (entry.record.novel, entry.isRemoved ? .removed : .live)
    case .unreadable: (Record.kind == .novel ? novelID(of: ref) : try? NovelForgeKey(reading: state, of: ref).novel, .unreadable)
    }
  }

  private static func appended<Record: AppendedRecord>(_: Record.Type, _ ref: EntityRef, _ state: EntityState) -> (UUID?, IndexedStatus)? {
    switch Record.reading(state, of: ref) {
    case .absent: nil
    case .readable(let entry): (entry.record.novel, .live)
    case .unreadable: (Record.attributedNovel(in: state), .unreadable)
    }
  }
}

func novelID(of ref: EntityRef) -> UUID? {
  guard NovelForgeKind(ref.kind) == .novel, let id = UUID(uuidString: ref.key.rawValue), NovelForgeKey.novel(id) == ref else { return nil }
  return id
}

extension AppendedRecord {
  static func attributedNovel(in state: EntityState) -> UUID? {
    guard case .appended(let appended) = state, let reader = FieldReader<Member>(object: .object(appended.item)) else { return nil }
    return try? reader.required(novelMember)
  }
}
