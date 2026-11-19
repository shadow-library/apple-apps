import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// What a final chapter's canon recorded at finalize of the knowledge it committed: nothing (readers recompute), the pairs, or a member this version cannot read.
enum FrozenKnowledgeState: String, Sendable, DatabaseValueConvertible {
  case absent
  case recorded
  case unreadable
}

/// The finalize review and knowledge a final chapter's winning canon binds, as canonical JSON text so a stored row compares by its bytes; one row per readable
/// canon that recorded either.
public struct CanonBindingEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_canon_binding"

  public let key: EntityKey
  public let novel: UUID
  public let chapter: Int
  /// When the canon that stands was written (its first-writer-wins clock).
  public let clock: HLCTimestamp
  /// The kept effective changes in the review's order; nil when the canon applied no review this version can read.
  let kept: String?
  let knowledgeState: FrozenKnowledgeState
  /// The committed (fact, entity) pairs when `knowledgeState` is `recorded`.
  let knowledge: String?

  init(key: EntityKey, novel: UUID, chapter: Int, clock: HLCTimestamp, kept: String?, knowledgeState: FrozenKnowledgeState, knowledge: String?) {
    self.key = key
    self.novel = novel
    self.chapter = chapter
    self.clock = clock
    self.kept = kept
    self.knowledgeState = knowledgeState
    self.knowledge = knowledge
  }

  public init(row: Row) throws {
    guard let key = EntityKey(try row.decode(String.self, forColumn: "key")), let clock = HLCTimestamp(try row.decode(String.self, forColumn: "clock")) else {
      throw StoreError.corruptStore("a canon binding entry holds an invalid key or clock")
    }
    self.init(
      key: key, novel: try row.decode(UUID.self, forColumn: "novel"), chapter: try row.decode(Int.self, forColumn: "chapter"), clock: clock,
      kept: try row.decode(String?.self, forColumn: "kept"), knowledgeState: try row.decode(FrozenKnowledgeState.self, forColumn: "knowledge_state"),
      knowledge: try row.decode(String?.self, forColumn: "knowledge"))
  }

  public var ref: EntityRef { EntityRef(kind: NovelForgeKind.finalChapter.entityKind, key: key) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["key"] = key.rawValue
    container["novel"] = novel
    container["chapter"] = chapter
    container["clock"] = clock.description
    container["kept"] = kept
    container["knowledge_state"] = knowledgeState
    container["knowledge"] = knowledge
  }
}

// Decision 3: what a kept item changes is derived from the canon that won, never written, so two devices that finalized the same chapter with different answers
// agree once the first writer's canon reaches both. A canon this version cannot read binds nothing.
public struct CanonBindingDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_canon_binding (
      key TEXT PRIMARY KEY, novel BLOB NOT NULL, chapter INTEGER NOT NULL, clock TEXT NOT NULL, kept TEXT, knowledge_state TEXT NOT NULL, knowledge TEXT
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_canon_binding_novel ON nf_derived_canon_binding (novel, chapter);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.records([.finalChapter]) { [$0] }]
  }

  public static func key(of output: CanonBindingEntry) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<CanonBindingEntry> {
    CanonBindingEntry.filter(Column("key") == ref.key.rawValue)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .finalChapter))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [CanonBindingEntry] {
    let state = try context.records.state(of: ref, scope: .vault)
    guard case .readable(let entry) = FinalChapterRecord.reading(state, of: ref), case .revisioned(let revisioned)? = state,
      let clock = revisioned[field: FinalChapterField.canon.rawValue]?.clock
    else { return [] }
    let canon = entry.record.canon
    let knowledge: (state: FrozenKnowledgeState, pairs: String?)
    if let pairs = canon.knowledge {
      let items = pairs.map { JSONValue.object([CanonLearnMember.fact.rawValue: .string($0.factKey), CanonLearnMember.entity.rawValue: .string($0.entityKey)]) }
      knowledge = (.recorded, CanonJSON.text(.array(items)))
    } else {
      knowledge = (canon.unrecognised[FinalChapterCanonMember.knowledge.rawValue] == nil ? .absent : .unreadable, nil)
    }
    let kept = canon.review.map { CanonJSON.text(.array($0.kept.map(JSONValue.object))) }
    guard kept != nil || knowledge.state != .absent else { return [] }
    return [
      CanonBindingEntry(
        key: ref.key, novel: entry.record.novel, chapter: entry.record.chapter, clock: clock, kept: kept, knowledgeState: knowledge.state, knowledge: knowledge.pairs)
    ]
  }
}

enum CanonJSON {
  static func text(_ value: JSONValue) -> String {
    String(decoding: CanonicalJSON.encode(value), as: UTF8.self)
  }

  static func value(_ text: String) throws(StoreError) -> JSONValue {
    do {
      return try CanonicalJSON.decode(Data(text.utf8))
    } catch {
      throw .corruptStore("a canon-derived row holds unreadable JSON")
    }
  }
}

/// One winning canon's binding as the canon-derived aggregates replay it. A kept change this version cannot read is left out, so it changes nothing.
struct CanonBinding: Sendable {
  enum Knowledge: Sendable {
    case absent
    case recorded([LedgerPair])
    case unreadable
  }

  let chapter: Int
  let clock: HLCTimestamp
  let kept: [ProposedChange]
  let knowledge: Knowledge

  init(_ entry: CanonBindingEntry) throws(StoreError) {
    chapter = entry.chapter
    clock = entry.clock
    kept = try entry.kept.map { text throws(StoreError) in try CanonJSON.value(text).arrayValue?.compactMap(ProposedChange.init(json:)) ?? [] } ?? []
    switch entry.knowledgeState {
    case .absent: knowledge = .absent
    case .unreadable: knowledge = .unreadable
    case .recorded:
      let items = try entry.knowledge.map { text throws(StoreError) in try CanonJSON.value(text).arrayValue ?? [] } ?? []
      knowledge = .recorded(
        items.compactMap { item in
          guard let fact = item.objectValue?[CanonLearnMember.fact.rawValue]?.stringValue, let entity = item.objectValue?[CanonLearnMember.entity.rawValue]?.stringValue
          else { return nil }
          return LedgerPair(factKey: fact, entityKey: entity)
        })
    }
  }

  /// The novel's bindings in chapter order, the order the reference committed them in (FIN_001).
  static func all(of novel: UUID, in context: DerivationContext) throws(StoreError) -> [CanonBinding] {
    var bindings = [CanonBinding]()
    for entry in try context.fetchAll(CanonBindingEntry.filter(Column("novel") == novel).order(Column("chapter"))) { bindings.append(try CanonBinding(entry)) }
    return bindings
  }

  /// By NFC key, the earliest winning canon keeping the entity as new; each device committing a chapter creates it, so `removed` ends at the latest create.
  static func keptAsNew(in bindings: [CanonBinding]) -> [JSString: HLCTimestamp] {
    var since = [JSString: HLCTimestamp]()
    for binding in bindings {
      for case .entity(let entity) in binding.kept {
        let key = JSString(entity.entityKey.jsNormalize(.nfc))
        since[key] = since[key].map { min($0, binding.clock) } ?? binding.clock
      }
    }
    return since
  }

  /// Deviation: once re-created, a `keptAsNew` entity regains every canon and approval since that clock, even those made while removed; the reference starts fresh.
  /// Still lost until an earliest-create clock exists: on three devices, a losing ch1 canon's create of the entity re-created after ch2 drops ch2's rows of it.
  static func liveSince(_ key: String, record: HLCTimestamp?, keptAsNew: [JSString: HLCTimestamp]) -> HLCTimestamp? {
    guard let record else { return nil }
    guard let kept = keptAsNew[JSString(key.jsNormalize(.nfc))] else { return record }
    return min(record, kept)
  }
}
