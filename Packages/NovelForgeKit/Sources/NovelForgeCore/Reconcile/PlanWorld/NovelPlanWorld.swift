import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Synchronization

public enum ClaimBasis: String, Codable, CaseIterable, Sendable {
  case plan
  case canon
}

/// A chapter as the plan world sees it: a final chapter through its canon, any other through the head of its plan. Keys are NFC.
struct WorldChapter: Codable, Equatable, Sendable {
  let chapter: Int
  let basis: ClaimBasis
  let volume: String?
  let ending: Bool
  let claims: [String]
  let pov: [String]
  let learns: [WorldLearn]

  init(_ reading: ChapterContractReading) {
    chapter = reading.entry.chapter
    basis = reading.entry.basis
    volume = reading.entry.volume
    ending = reading.entry.ending
    claims = reading.terms.claims
    pov = reading.terms.pov
    learns = reading.terms.learns
  }

  var plan: DisclosurePlan { plan(learning: learns) }

  // The contract in the shape apps/novel-forge-server/src/common/knowledge-contract.ts:13 parses
  func plan(learning learns: [WorldLearn]) -> DisclosurePlan {
    let learned = learns.map { learn in
      OrderedJSON.object(OrderedJSONObject([(key: "entityKey", value: .string(learn.entity)), (key: "factKey", value: .string(learn.fact))]))
    }
    let knowledge = OrderedJSON.object(OrderedJSONObject([(key: "pov", value: .array(pov.map(OrderedJSON.string))), (key: "learns", value: .array(learned))]))
    let claims = PlanClaims(chapter: chapter, volumeKey: volume, isEnding: ending, claimedMilestones: claims)
    return DisclosurePlan(normalizing: claims, knowledgeContract: knowledge, endingContract: .null)
  }
}

struct WorldFact: Codable, Equatable, Sendable {
  let fact: String
  let revealChapter: Int?
  let source: FactSource?
  let unlock: UnlockCondition?
  let unlockReadable: Bool

  init(_ fact: DisclosureFact) {
    self.fact = fact.factKey
    revealChapter = fact.revealChapter
    source = fact.source
    switch fact.unlock {
    case nil: (unlock, unlockReadable) = (nil, true)
    case .condition(let condition)?: (unlock, unlockReadable) = (condition, true)
    case .unreadable?: (unlock, unlockReadable) = (nil, false)
    }
  }

  var disclosureFact: DisclosureFact {
    DisclosureFact(factKey: fact, text: "", source: source, revealChapter: revealChapter, unlock: unlockReadable ? unlock.map(FactUnlock.condition) : .unreadable)
  }
}

struct WorldVolume: Codable, Equatable, Sendable {
  let volume: String
  let ordinal: Int
}

/// The chapters that claim one milestone. A canon's claim reached it and outranks every plan's, so the milestone's state and its holder never disagree.
struct ClaimTally {
  var canon: [Int] = []
  var plan: [Int] = []

  var reachedChapter: Int? { canon.min() }
  var holder: Int? { canon.min() ?? plan.min() }

  // apps/novel-forge-server/src/common/plan-state.ts:168 reaches a final chapter's claims; reveal-rule.ts:142 plans the rest at the earliest claim
  var state: MilestoneState {
    if !canon.isEmpty { return .reached }
    return plan.isEmpty ? .open : .planned
  }
}

private let unreadableSecretRequirement = "a readable secret"

// apps/novel-forge-server/src/common/plan-world.ts:39 (loadPlanState) for one novel, loaded once per change by PlanWorldDerivation and stored for the derivations after it
struct NovelPlanWorld: Codable, Equatable, Sendable {
  private(set) var frontier = 0
  private(set) var chapters: [WorldChapter] = []
  /// Chapters whose plan is not removed, readable or not.
  private(set) var plans: [Int] = []
  private(set) var unreadablePlans: [Int] = []
  private(set) var milestones: [String] = []
  private(set) var facts: [WorldFact] = []
  private(set) var unreadableSecrets: [String] = []
  private(set) var volumes: [WorldVolume] = []

  static let recordKinds: [NovelForgeKind] = [.milestone, .secret, .volume]

  /// Nil for a novel with none of the records the plan world reads.
  static func load(novel: UUID, in context: DerivationContext) throws(StoreError) -> NovelPlanWorld? {
    var world = NovelPlanWorld()
    var finals = [Int: ChapterContractReading]()
    var heads = [Int: ChapterContractReading]()
    let entries = try ChapterContractEntry.all(of: novel, in: context)
    let rows = try context.fetchAll(IndexedRecord.filter(Column("novel") == novel && recordKinds.map(\.rawValue).contains(Column("kind"))))
    guard !entries.isEmpty || !rows.isEmpty else { return nil }
    for reading in entries {
      switch reading.entry.basis {
      case .canon: finals[reading.entry.chapter] = reading
      case .plan: heads[reading.entry.chapter] = reading
      }
    }
    // plan-world.ts:29 (planFrontier): the story cursor never passes the latest final chapter
    world.frontier = finals.keys.max() ?? 0
    world.plans = heads.keys.sorted()
    world.unreadablePlans = heads.values.filter { !$0.entry.readable }.map(\.entry.chapter).sorted()
    for chapter in Set(finals.keys).union(heads.keys).sorted() {
      guard let reading = finals[chapter] ?? heads[chapter], reading.entry.readable else { continue }
      world.chapters.append(WorldChapter(reading))
    }

    var ordinals = [JSString: Int]()
    var unreadableSecrets = [String]()
    for row in rows {
      let state = try context.records.state(of: row.ref, scope: .vault)
      switch row.kind {
      case .milestone:
        switch MilestoneRecord.reading(state, of: row.ref) {
        case .absent: continue
        case .readable(let entry): if !entry.isRemoved { world.milestones.append(entry.record.milestone) }
        case .unreadable: if case .milestone(let key)? = components(state, row.ref) { world.milestones.append(key) }
        }
      case .secret:
        switch SecretRecord.reading(state, of: row.ref) {
        case .absent: continue
        case .readable(let entry): if !entry.isRemoved { world.facts.append(WorldFact(DisclosureFact(secret: entry.record, disclosedInChapter: nil))) }
        case .unreadable: if case .secret(let key)? = components(state, row.ref) { unreadableSecrets.append(key) }
        }
      case .volume:
        guard case .readable(let entry) = VolumeRecord.reading(state, of: row.ref), !entry.isRemoved else { continue }
        ordinals[JSString(entry.record.volume)] = entry.record.ordinal
      default: continue
      }
    }
    world.milestones = world.milestones.jsUnique().jsSorted()
    world.facts.sort { JSText.codeUnitPrecedes($0.fact, $1.fact) }
    world.unreadableSecrets = unreadableSecrets.jsUnique().jsSorted()
    world.volumes = ordinals.map { WorldVolume(volume: $0.key.value, ordinal: $0.value) }.sorted { JSText.codeUnitPrecedes($0.volume, $1.volume) }
    return world
  }

  // The three derivations after PlanWorldDerivation read the same bytes in one pass, so the last decoding is kept rather than repeated.
  private static let lastDecoded = Mutex<(bytes: Data, world: NovelPlanWorld)?>(nil)

  /// Stored bytes this version cannot decode (written before a change of these types' shapes) are loaded again from the records instead.
  static func stored(for novel: UUID, in context: DerivationContext) throws(StoreError) -> NovelPlanWorld? {
    guard let entry = try context.fetchAll(PlanWorldDerivation.request(for: novel)).first else { return nil }
    if let last = lastDecoded.withLock({ $0 }), last.bytes == entry.world { return last.world }
    guard let world = try? JSONDecoder().decode(NovelPlanWorld.self, from: entry.world) else { return try load(novel: novel, in: context) }
    lastDecoded.withLock { $0 = (entry.world, world) }
    return world
  }

  /// Two devices can each mark a different plan as the ending; the latest one stands, so an ending-gated reveal unlocks no earlier than either device meant.
  static func keepingLatestEnding(_ plans: [DisclosurePlan]) -> [DisclosurePlan] {
    guard let latest = plans.filter(\.claims.isEnding).map(\.claims.chapter).max() else { return plans }
    return plans.map { plan in
      var plan = plan
      if plan.claims.chapter != latest { plan.row.claims.isEnding = false }
      return plan
    }
  }

  var latestEnding: Int? { chapters.filter(\.ending).map(\.chapter).max() }

  var claimTallies: [JSString: ClaimTally] {
    var tallies: [JSString: ClaimTally] = [:]
    for chapter in chapters {
      for key in chapter.claims {
        switch chapter.basis {
        case .canon: tallies[JSString(key), default: ClaimTally()].canon.append(chapter.chapter)
        case .plan: tallies[JSString(key), default: ClaimTally()].plan.append(chapter.chapter)
        }
      }
    }
    return tallies
  }

  var planWorld: PlanWorld {
    let tallies = claimTallies
    let rows = milestones.map { key in
      let tally = tallies[JSString(key)] ?? ClaimTally()
      return MilestoneRow(milestoneKey: key, state: tally.state, reachedChapter: tally.reachedChapter)
    }
    var ordinals = [JSString: Int]()
    for volume in volumes { ordinals[JSString(volume.volume)] = volume.ordinal }
    return PlanWorld(plans: Self.keepingLatestEnding(chapters.map(\.plan)).map(\.row), milestones: rows, volumeOrdinals: ordinals)
  }

  // apps/novel-forge-server/src/common/reveal-rule.ts:108 (findPlanRevealViolations); an unreadable secret or unlock never holds, where an unknown key is skipped
  var revealJudge: (PlanRow, UnlockContext) -> [PlanRevealViolation] {
    let factByKey = facts.map(\.disclosureFact).jsLastByKey(\.factKey)
    let unreadable = Set(unreadableSecrets.map { JSString($0) })
    return { plan, context in Self.revealViolations(of: plan, at: context, factByKey: factByKey, unreadable: unreadable) }
  }

  private static func revealViolations(of plan: PlanRow, at context: UnlockContext, factByKey: [JSString: DisclosureFact], unreadable: Set<JSString>)
    -> [PlanRevealViolation]
  {
    learnedFactKeys(plan.knowledgeContract).compactMap { factKey in
      let slot = JSString(factKey)
      let missing = factByKey[slot].map { disclosureRequirements($0, context) } ?? (unreadable.contains(slot) ? [unreadableSecretRequirement] : [])
      return missing.isEmpty ? nil : PlanRevealViolation(fact: factKey, missing: missing)
    }
  }

  private static func components(_ state: EntityState?, _ ref: EntityRef) -> NovelForgeKey.Components? {
    guard let state else { return nil }
    return try? NovelForgeKey(reading: state, of: ref).components
  }
}

/// The novel's plan world as JSON bytes, compared byte for byte, so the three derivations after it never reload the novel's records.
struct PlanWorldEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "nf_derived_plan_world"

  let novel: UUID
  let world: Data
}

struct PlanWorldDerivation: Derivation {
  static let version = 1
  static let definition = """
    CREATE TABLE nf_derived_plan_world (novel BLOB PRIMARY KEY, world BLOB NOT NULL) STRICT, WITHOUT ROWID;
    """

  var inputs: [DerivationInput<UUID>] {
    [
      .outputs(of: ChapterContractDerivation.self) { [$0.novel] },
      .outputs(of: RecordIndexDerivation.self) { row in NovelPlanWorld.recordKinds.contains(row.kind) ? row.novel.map { [$0] } ?? [] : [] },
    ]
  }

  static func key(of output: PlanWorldEntry) -> UUID { output.novel }

  static func request(for novel: UUID) -> QueryInterfaceRequest<PlanWorldEntry> {
    PlanWorldEntry.filter(Column("novel") == novel)
  }

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    let chapters = try context.fetchAll(ChapterContractEntry.all()).map(\.novel)
    let records = try context.fetchAll(IndexedRecord.filter(NovelPlanWorld.recordKinds.map(\.rawValue).contains(Column("kind")))).compactMap(\.novel)
    return Set(chapters + records)
  }

  func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [PlanWorldEntry] {
    guard let world = try NovelPlanWorld.load(novel: novel, in: context) else { return [] }
    return [PlanWorldEntry(novel: novel, world: try sortedJSON(world))]
  }
}
