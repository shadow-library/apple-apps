import ShadowCore

/// A chapter's plan as the writer pack reads the reference's `briefs` row; a final chapter's claims and contract come from its canon.
struct WriterPackPlan: Equatable, Sendable {
  var chapter: Int
  var volume: String?
  var pov: String?
  var contextRefs: [String]
  var contract: ChapterContract
  var endingContract: ChapterEndingContract?
  var brief: WriterBriefInput

  var knowledge: KnowledgeContract? { contract.knowledge }

  var disclosurePlan: DisclosurePlan {
    let learns = contract.learns.map { learn in
      OrderedJSON.object(OrderedJSONObject([(key: "entityKey", value: .string(learn.reveal.entityKey)), (key: "factKey", value: .string(learn.reveal.factKey))]))
    }
    let knowledge = OrderedJSON.object(OrderedJSONObject([(key: "pov", value: .array(contract.pov.map(OrderedJSON.string))), (key: "learns", value: .array(learns))]))
    let claims = PlanClaims(chapter: chapter, volumeKey: volume, isEnding: contract.isEnding, claimedMilestones: contract.claimedMilestones)
    return DisclosurePlan(normalizing: claims, knowledgeContract: knowledge, endingContract: endingContract.map(Self.referenceShape) ?? .null)
  }

  /// The ending contract as the reference stores it: the record's members are snake_case, the loaders read camelCase.
  private static func referenceShape(_ contract: ChapterEndingContract) -> OrderedJSON {
    var members: [(key: String, value: OrderedJSON)] = [
      ("hookType", .string(contract.hookType.rawValue)), ("emotionalBeat", .string(contract.emotionalBeat)), ("openQuestion", .string(contract.openQuestion)),
      ("handoffState", .string(contract.handoffState)),
    ]
    if let entries = contract.mustNotResolve { members.append(("mustNotResolve", .array(entries.map(OrderedJSON.string)))) }
    return .object(OrderedJSONObject(members))
  }
}

/// A final chapter: the reference's `chapters` row, whose status is always `done` here. `volume` is the volume it was imported into.
struct WriterPackFinal: Equatable, Sendable {
  var chapter: Int
  var title: String?
  var body: String
  var summary: String?
  var isolated: Bool
  var volume: String?
}

struct WriterPackDraft: Equatable, Sendable {
  var chapter: Int
  var body: String
  var summary: String?
  var state: OrderedJSON?
  var isolated: Bool
  var staleReason: String?
}

struct WriterPackVolume: Equatable, Sendable {
  var volume: String
  var ordinal: Int
  var title: String?
  var objective: String?
  var body: String?
  var goalMet: Bool
}

struct WriterPackEntity: Equatable, Sendable {
  var entity: String
  var name: String
  var type: String
  var status: String?
  var body: String?
  var notes: String?
  var aliases: [String] = []
}

struct WriterPackCharacterState: Equatable, Sendable {
  var entity: String
  var location: String?
  var conditions: [String]?
  var immediateGoal: String?
  var statusNote: String?
  var lastUpdatedChapter: Int
}

/// `order` is the row's insertion order, which breaks a tie between two observations of one pair in the same chapter.
struct WriterPackRelationship: Equatable, Sendable {
  var entity: String
  var target: String
  var kind: String
  var note: String?
  var chapter: Int?
  var order: Int
}

struct WriterPackWorldFact: Equatable, Sendable {
  var category: String
  var key: String
  var value: String
}

struct WriterPackThread: Equatable, Sendable {
  var thread: String
  var status: String
  var openedChapter: Int?
  var closedChapter: Int?
  var summary: String?
}

struct WriterPackMystery: Equatable, Sendable {
  var mystery: String
  var status: String
  var openedChapter: Int?
  var question: String
}

/// Everything `forChapter` reads of one novel, as the reference's tables hold it. Facts are in key order (the reference reads them ordered by key where order
/// matters), entities in key order, world facts in category then key order. The vault keeps no aliases, character states, relationships or world facts yet,
/// so a world loaded from it has none.
// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:196-222 and the queries of the helpers it calls
struct WriterPackWorld: Equatable, Sendable {
  var writingStyle: String?
  var ending: String?
  var endingQuestion: String?
  var plans: [WriterPackPlan] = []
  var finals: [WriterPackFinal] = []
  var drafts: [WriterPackDraft] = []
  var volumes: [WriterPackVolume] = []
  var milestones: [MilestoneRow] = []
  var facts: [DisclosureFact] = []
  var knowledge: [KnowledgeRow] = []
  var entities: [WriterPackEntity] = []
  var characterStates: [WriterPackCharacterState] = []
  var relationships: [WriterPackRelationship] = []
  var worldFacts: [WriterPackWorldFact] = []
  var threads: [WriterPackThread] = []
  var mysteries: [WriterPackMystery] = []
  var pages: [DisclosurePage] = []
  var ledger: [ChatPackLedgerEntry] = []

  func plan(for chapter: Int) -> WriterPackPlan? { plans.first { $0.chapter == chapter } }

  func final(_ chapter: Int) -> WriterPackFinal? { finals.first { $0.chapter == chapter } }

  func draft(_ chapter: Int) -> WriterPackDraft? { drafts.first { $0.chapter == chapter } }

  func entity(_ key: String) -> WriterPackEntity? { entities.last { $0.entity.jsEquals(key) } }

  var volumesByOrdinal: [WriterPackVolume] { volumes.jsStableSorted { $0.ordinal < $1.ordinal } }

  var disclosureWorld: DisclosureWorld {
    DisclosureWorld(
      ending: ending, endingQuestion: endingQuestion, facts: facts, entities: entities.map { DisclosureEntity(entityKey: $0.entity, name: $0.name) }, knowledge: knowledge,
      plans: NovelPlanWorld.keepingLatestEnding(plans.map(\.disclosurePlan)), milestones: milestones,
      volumes: volumesByOrdinal.map { DisclosureVolume(volumeKey: $0.volume, ordinal: $0.ordinal, title: $0.title, objective: $0.objective, body: $0.body) },
      pages: pages)
  }
}
