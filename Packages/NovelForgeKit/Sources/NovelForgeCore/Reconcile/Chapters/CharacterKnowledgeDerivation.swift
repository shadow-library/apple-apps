import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// One pair of the novel's knowledge ledger: the author's manual reveal, or the earliest final or approved chapter whose contract teaches it. `draftRevision` is
/// the revision that chapter's canon or approval names, for a plan row only.
public struct CharacterKnowledgeEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_character_knowledge"

  public let novel: UUID
  public let fact: String
  public let entity: String
  public let chapter: Int
  public let source: FactSource
  public let status: KnowledgeStatus
  public let draftRevision: String?

  init(novel: UUID, fact: String, entity: String, chapter: Int, source: FactSource, status: KnowledgeStatus, draftRevision: String?) {
    self.novel = novel
    self.fact = fact
    self.entity = entity
    self.chapter = chapter
    self.source = source
    self.status = status
    self.draftRevision = draftRevision
  }

  public init(row: Row) throws {
    guard let source = FactSource(rawValue: try row.decode(String.self, forColumn: "source")),
      let status = KnowledgeStatus(rawValue: try row.decode(String.self, forColumn: "status"))
    else { throw StoreError.corruptStore("a character knowledge entry holds an unknown source or status") }
    self.init(
      novel: try row.decode(UUID.self, forColumn: "novel"), fact: try row.decode(String.self, forColumn: "fact"), entity: try row.decode(String.self, forColumn: "entity"),
      chapter: try row.decode(Int.self, forColumn: "chapter"), source: source, status: status, draftRevision: try row.decode(String?.self, forColumn: "draft"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["novel"] = novel
    container["fact"] = fact
    container["entity"] = entity
    container["chapter"] = chapter
    container["source"] = source.rawValue
    container["status"] = status.rawValue
    container["draft"] = draftRevision
  }
}

/// A chapter whose contract the ledger takes: final ones commit, approved ones are provisional. `since` is the clock of the approval it rests on. A final chapter
/// whose canon recorded its knowledge commits exactly `frozen` in place of its contract's learns, and `generated` holds the knowledge items its review kept.
struct KnowledgeContributor: Equatable {
  let chapter: Int
  let isFinal: Bool
  let since: HLCTimestamp?
  var frozen: [LedgerPair]? = nil
  var generated: [LedgerPair] = []
}

enum DerivedLedger {
  /// apps/novel-forge-server/src/common/provisional-knowledge.ts:88 and 163 replayed in chapter order on the current world: each contributor is ledgered as an
  /// approval would, and a final one committed as finalize would, so every pair lands at its earliest contributor and a manual row stays authoritative. A pair
  /// the author retracted stays hidden, whichever chapter claims it. `plans` are the world's chapters with each contributor's learns cut to what it could ledger.
  /// A frozen contributor commits the pairs its finalizing device recorded, which the reveal rule is not asked about again.
  static func rows(
    world: NovelPlanWorld, plans: [DisclosurePlan], entities: [String], manual: [KnowledgeRow], retracted: Set<LedgerPair>, contributors: [KnowledgeContributor]
  ) -> [KnowledgeRow] {
    var ledger = world.disclosureWorld(plans: plans, entities: entities, knowledge: manual)
    let contexts = plannedUnlockContexts(ledger.planWorld, conditioned: true)
    for contributor in contributors.sorted(by: { $0.chapter < $1.chapter }) {
      if let frozen = contributor.frozen {
        ledger.writeBriefReveals(
          frozen.map { KnowledgeRow(factKey: $0.factKey, entityKey: $0.entityKey, learnedInChapter: contributor.chapter, source: .brief, status: .committed) })
      } else {
        ledger.ledgerBriefReveals(chapter: contributor.chapter, draftRevision: contributor.chapter, contexts: contexts)
        if contributor.isFinal { ledger.commitProvisionalRows(chapter: contributor.chapter, draftRevision: contributor.chapter) }
      }
      // review-event-apply.ts:203-214, after commitChapterKnowledge (chapter-finalization.graph.ts:175-176): a kept item never displaces a row the pair holds
      for pair in contributor.generated where !ledger.knowledge.contains(where: { $0.pair == pair }) {
        ledger.knowledge.append(
          KnowledgeRow(factKey: pair.factKey, entityKey: pair.entityKey, learnedInChapter: contributor.chapter, source: .generated, status: .committed))
      }
    }
    return ledger.ledger.filter { $0.source == .manual || !retracted.contains($0.pair) }
  }
}

extension NovelPlanWorld {
  /// The world as the reference's loaders read it, with `plans` in place of the world's chapters and the latest ending standing.
  func disclosureWorld(plans: [DisclosurePlan], entities: [String] = [], knowledge: [KnowledgeRow] = []) -> DisclosureWorld {
    DisclosureWorld(
      facts: facts.map(\.disclosureFact), entities: entities.map { DisclosureEntity(entityKey: $0, name: "") }, knowledge: knowledge,
      plans: NovelPlanWorld.keepingLatestEnding(plans), milestones: planWorld.milestones,
      volumes: volumes.map { DisclosureVolume(volumeKey: $0.volume, ordinal: $0.ordinal) }, readerKnowsLabel: false)
  }
}

extension DisclosureVolume {
  init(volumeKey: String, ordinal: Int) {
    self.init(volumeKey: volumeKey, ordinal: ordinal, title: nil, objective: nil, body: nil)
  }
}

// Committed knowledge from final chapters (the pairs a canon recorded at finalize, else its contract's learns, then the knowledge items its review kept) and
// provisional knowledge from approvals in force, over the author's manual reveals; a removed secret or entity hides its rows, and one restored or created again
// starts with none, as the reference's delete cascades them (database/schemas/knowledge.ts:188-191).
public struct CharacterKnowledgeDerivation: Derivation {
  public static let version = 4
  public static let definition = """
    CREATE TABLE nf_derived_character_knowledge (
      novel BLOB NOT NULL, fact TEXT NOT NULL, entity TEXT NOT NULL, chapter INTEGER NOT NULL, source TEXT NOT NULL, status TEXT NOT NULL, draft TEXT,
      PRIMARY KEY (novel, fact, entity)
    ) STRICT, WITHOUT ROWID;
    """

  // A secret's live-since clock moves when another device's creation of it arrives, leaving the plan world as it was.
  static let recordKinds: [NovelForgeKind] = [.entity, .secret, .characterKnowledge]

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [
      .outputs(of: FinalChapterDerivation.self) { [$0.novel] },
      .outputs(of: PlanWorldDerivation.self) { [$0.novel] },
      .outputs(of: ApprovalInForceDerivation.self) { [$0.novel] },
      .outputs(of: ChapterApprovalDerivation.self) { [$0.novel] },
      .outputs(of: CanonBindingDerivation.self) { [$0.novel] },
      .outputs(of: RecordIndexDerivation.self) { row in Self.recordKinds.contains(row.kind) ? row.novel.map { [$0] } ?? [] : [] },
    ]
  }

  public static func key(of output: CharacterKnowledgeEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<CharacterKnowledgeEntry> {
    CharacterKnowledgeEntry.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(PlanWorldEntry.all()).map(\.novel))
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [CharacterKnowledgeEntry] {
    guard let world = try NovelPlanWorld.stored(for: novel, in: context) else { return [] }
    var revisions = [Int: String?]()
    var contributors = [KnowledgeContributor]()
    let finals = try context.fetchAll(FinalChapterEntry.filter(Column("novel") == novel))
    let bindings = Dictionary(try CanonBinding.all(of: novel, in: context).map { ($0.chapter, $0) }) { first, _ in first }
    let bound = Set(finals.compactMap(\.approval))
    var approved = [UUID: HLCTimestamp]()
    if !bound.isEmpty {
      for item in try context.fetchAll(ChapterApprovalEntry.filter(Column("novel") == novel)) where bound.contains(item.id) { approved[item.id] = item.clock }
    }
    for final in finals {
      revisions[final.chapter] = .some(final.draftRevision)
      // provisional-knowledge.ts:73-96 and 163-175: finalize commits only what its bound approval ledgered; an approval not yet readable here commits nothing.
      let since: HLCTimestamp?
      if let named = final.approval {
        since = approved[named].map { approval in final.canonClock.map { min($0, approval) } ?? approval }
      } else {
        since = final.canonClock
      }
      var contributor = KnowledgeContributor(chapter: final.chapter, isFinal: true, since: since)
      if let binding = bindings[final.chapter] {
        switch binding.knowledge {
        case .absent: break
        case .recorded(let pairs): contributor.frozen = pairs
        case .unreadable: contributor.frozen = []
        }
        contributor.generated = binding.kept.compactMap { change in
          guard case .knowledge(let knowledge) = change else { return nil }
          return LedgerPair(factKey: knowledge.factKey.jsNormalize(.nfc), entityKey: knowledge.entityKey.jsNormalize(.nfc))
        }
      }
      contributors.append(contributor)
    }
    for approved in try context.fetchAll(ApprovalInForceDerivation.request(for: novel)) where revisions[approved.chapter] == nil {
      revisions[approved.chapter] = .some(approved.draftRevision)
      contributors.append(KnowledgeContributor(chapter: approved.chapter, isFinal: false, since: approved.clock))
    }

    var manual = [KnowledgeRow]()
    var retracted = Set<LedgerPair>()
    let rows = try context.fetchAll(IndexedRecord.filter(Column("novel") == novel && Column("kind") == NovelForgeKind.characterKnowledge.rawValue))
    for row in rows {
      let state = try context.records.state(of: row.ref, scope: .vault)
      switch CharacterKnowledgeRecord.reading(state, of: row.ref) {
      case .absent: continue
      case .readable(let entry):
        if entry.isRemoved {
          retracted.insert(LedgerPair(factKey: entry.record.fact, entityKey: entry.record.entity))
        } else {
          manual.append(KnowledgeRow(manual: entry.record))
        }
      case .unreadable:
        guard let state, case .characterKnowledge(let fact, let entity)? = try? NovelForgeKey(reading: state, of: row.ref).components else { continue }
        retracted.insert(LedgerPair(factKey: fact, entityKey: entity))
      }
    }

    let since = Dictionary(contributors.map { ($0.chapter, $0.since) }) { first, _ in first }
    var named = Set(manual.map { JSString($0.entityKey) })
    var facts = Set<JSString>()
    for chapter in world.chapters where since[chapter.chapter] != nil {
      named.formUnion(chapter.learns.map { JSString($0.entity) })
      facts.formUnion(chapter.learns.map { JSString($0.fact) })
    }
    for pair in contributors.flatMap({ ($0.frozen ?? []) + $0.generated }) {
      named.insert(JSString(pair.entityKey))
      facts.insert(JSString(pair.factKey))
    }
    var entities = [String]()
    var entityLive = [JSString: HLCTimestamp]()
    for key in named.sorted() {
      let ref = EntityRecord.ref(novel: novel, entity: key.value)
      let state = try context.records.state(of: ref, scope: .vault)
      guard case .readable(let entry) = EntityRecord.reading(state, of: ref), !entry.isRemoved else { continue }
      entities.append(key.value)
      entityLive[key] = state?.liveSince
    }
    var factLive = [JSString: HLCTimestamp]()
    for key in facts { factLive[key] = try context.records.state(of: SecretRecord.ref(novel: novel, secret: key.value), scope: .vault)?.liveSince }

    // provisional-knowledge.ts:73-79 skips a learn whose fact or learner did not exist when the chapter was approved, and finalize commits only what was
    // ledgered; a record removed and then restored or created again is a new row there (fact.handler.ts:61), so it counts from its latest create or restore.
    // The reference's re-ledgering of a revoked pair (provisional-knowledge.ts:183-232) skips this check at the earliest other claimant; here it holds there too.
    let wasLive = { (fact: String, entity: String, cutoff: HLCTimestamp?) -> Bool in
      guard let cutoff, let since = factLive[JSString(fact)], let learner = entityLive[JSString(entity)] else { return false }
      return since <= cutoff && learner <= cutoff
    }
    let plans = world.chapters.map { chapter -> DisclosurePlan in
      guard let cutoff = since[chapter.chapter] else { return chapter.plan }
      return chapter.plan(learning: chapter.learns.filter { wasLive($0.fact, $0.entity, cutoff) })
    }
    // review-event-apply.ts:204-209 skips a kept item whose fact or learner does not exist at the commit the canon records.
    let committed = contributors.map { contributor in
      var cut = contributor
      cut.frozen = contributor.frozen?.filter { wasLive($0.factKey, $0.entityKey, contributor.since) }
      cut.generated = contributor.generated.filter { wasLive($0.factKey, $0.entityKey, bindings[contributor.chapter]?.clock) }
      return cut
    }
    let ledger = DerivedLedger.rows(world: world, plans: plans, entities: entities, manual: manual, retracted: retracted, contributors: committed)
    return ledger.map { row in
      let revision = row.source == .manual ? nil : revisions[row.learnedInChapter] ?? nil
      return CharacterKnowledgeEntry(
        novel: novel, fact: row.factKey, entity: row.entityKey, chapter: row.learnedInChapter, source: row.source ?? .manual, status: row.status, draftRevision: revision)
    }
  }
}
