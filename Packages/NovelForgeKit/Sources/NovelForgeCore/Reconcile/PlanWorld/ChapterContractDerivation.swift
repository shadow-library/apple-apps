import Foundation
import GRDB
import ShadowCore
import ShadowStore

struct WorldLearn: Codable, Hashable, Sendable {
  let entity: String
  let fact: String
}

struct ChapterTerms: Codable, Hashable, Sendable {
  let claims: [String]
  let pov: [String]
  let learns: [WorldLearn]

  static let none = ChapterTerms(claims: [], pov: [], learns: [])
}

/// Sorted keys, so equal values give equal bytes on every replica.
func sortedJSON<Value: Encodable>(_ value: Value) throws(StoreError) -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  do {
    return try encoder.encode(value)
  } catch {
    throw .corruptStore("a derived value cannot be encoded")
  }
}

/// What the plan world reads of one plan or final chapter, keys in NFC, so a per-novel aggregate never decodes a whole chapter again. `terms` holds the JSON of
/// `ChapterTerms`, kept as bytes so a stored row never fails to load; a row whose terms this version cannot decode is read again from its record.
struct ChapterContractEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "nf_derived_chapter_contract"

  let basis: ClaimBasis
  let key: EntityKey
  let novel: UUID
  let chapter: Int
  let readable: Bool
  let volume: String?
  let ending: Bool
  let terms: Data

  static func unreadable(_ basis: ClaimBasis, _ ref: EntityRef, novel: UUID, chapter: Int) throws(StoreError) -> ChapterContractEntry {
    ChapterContractEntry(basis: basis, key: ref.key, novel: novel, chapter: chapter, readable: false, volume: nil, ending: false, terms: try sortedJSON(ChapterTerms.none))
  }

  static func reading(_ basis: ClaimBasis, _ ref: EntityRef, novel: UUID, chapter: Int, volume: String?, contract: ChapterContract) throws(StoreError)
    -> ChapterContractEntry
  {
    let nfc = { (text: String) in text.jsNormalize(.nfc) }
    let terms = ChapterTerms(
      claims: contract.claimedMilestones.map(nfc).jsUnique(), pov: contract.pov.map(nfc),
      learns: contract.learns.map { WorldLearn(entity: nfc($0.reveal.entityKey), fact: nfc($0.reveal.factKey)) })
    return ChapterContractEntry(
      basis: basis, key: ref.key, novel: novel, chapter: chapter, readable: true, volume: volume.map(nfc), ending: contract.isEnding, terms: try sortedJSON(terms))
  }

  /// A novel's rows with their terms decoded by one JSON decoder: GRDB's per-row decoding dominated a large novel's load.
  static func all(of novel: UUID, in context: DerivationContext) throws(StoreError) -> [ChapterContractReading] {
    let decoder = JSONDecoder()
    var readings = [ChapterContractReading]()
    for entry in try context.fetchAll(ChapterContractEntry.filter(Column("novel") == novel)) {
      if let terms = try? decoder.decode(ChapterTerms.self, from: entry.terms) {
        readings.append(ChapterContractReading(entry: entry, terms: terms))
        continue
      }
      for fresh in try ChapterContractDerivation().outputs(for: entry.ref, in: context) where fresh.novel == novel {
        guard let terms = try? decoder.decode(ChapterTerms.self, from: fresh.terms) else { continue }
        readings.append(ChapterContractReading(entry: fresh, terms: terms))
      }
    }
    return readings
  }

  var ref: EntityRef {
    EntityRef(kind: (basis == .canon ? NovelForgeKind.finalChapter : .chapterPlan).entityKind, key: key)
  }
}

struct ChapterContractReading {
  let entry: ChapterContractEntry
  let terms: ChapterTerms
}

// One row per plan that is not removed and per final chapter; a final chapter is read from its stored canon alone, never its digest, text or amendments.
struct ChapterContractDerivation: Derivation {
  static let version = 1
  static let definition = """
    CREATE TABLE nf_derived_chapter_contract (
      basis TEXT NOT NULL, key TEXT NOT NULL, novel BLOB NOT NULL, chapter INTEGER NOT NULL, readable INTEGER NOT NULL, volume TEXT, ending INTEGER NOT NULL,
      terms BLOB NOT NULL, PRIMARY KEY (basis, key)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_chapter_contract_novel ON nf_derived_chapter_contract (novel);
    """

  var inputs: [DerivationInput<EntityRef>] {
    [.records([.chapterPlan, .finalChapter]) { [$0] }]
  }

  static func key(of output: ChapterContractEntry) -> EntityRef { output.ref }

  static func request(for ref: EntityRef) -> QueryInterfaceRequest<ChapterContractEntry> {
    let basis: ClaimBasis = NovelForgeKind(ref.kind) == .finalChapter ? .canon : .plan
    return ChapterContractEntry.filter(Column("basis") == basis.rawValue && Column("key") == ref.key.rawValue)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(of: .chapterPlan) + context.refs(of: .finalChapter))
  }

  func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [ChapterContractEntry] {
    let state = try context.records.state(of: ref, scope: .vault)
    switch NovelForgeKind(ref.kind) {
    case .chapterPlan: return try Self.plan(state, ref)
    case .finalChapter: return try Self.final(state, ref)
    default: return []
    }
  }

  private static func plan(_ state: EntityState?, _ ref: EntityRef) throws(StoreError) -> [ChapterContractEntry] {
    switch ChapterPlanRecord.reading(state, of: ref) {
    case .absent:
      return []
    case .readable(let entry):
      guard !entry.isRemoved else { return [] }
      let record = entry.record
      return [try .reading(.plan, ref, novel: record.novel, chapter: record.chapter, volume: record.content.volume, contract: record.content.contract)]
    case .unreadable:
      guard let key = naturalKey(state, ref), case .chapterPlan(let chapter) = key.components else { return [] }
      return [try .unreadable(.plan, ref, novel: key.novel, chapter: chapter)]
    }
  }

  private static func final(_ state: EntityState?, _ ref: EntityRef) throws(StoreError) -> [ChapterContractEntry] {
    guard let state, !FinalChapterRecord.isPending(state), let key = naturalKey(state, ref), case .finalChapter(let chapter) = key.components else { return [] }
    guard case .revisioned(let revisioned) = state, let stored = revisioned[field: FinalChapterField.canon.rawValue]?.value,
      let reader = FieldReader<FinalChapterCanonMember>(object: stored)
    else { return [try .unreadable(.canon, ref, novel: key.novel, chapter: chapter)] }
    let terms: (volume: String?, contract: ChapterContract)?
    do throws(UnreadableReason) {
      terms = (try reader.optional(.volume), try reader.required(.contract))
    } catch {
      terms = nil
    }
    guard let terms else { return [try .unreadable(.canon, ref, novel: key.novel, chapter: chapter)] }
    return [try .reading(.canon, ref, novel: key.novel, chapter: chapter, volume: terms.volume, contract: terms.contract)]
  }

  private static func naturalKey(_ state: EntityState?, _ ref: EntityRef) -> NovelForgeKey? {
    guard let state else { return nil }
    return try? NovelForgeKey(reading: state, of: ref)
  }
}
