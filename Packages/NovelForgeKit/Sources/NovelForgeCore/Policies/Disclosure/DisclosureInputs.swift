import ShadowCore

/// A stored unlock the app cannot read (from a newer version, or malformed) never holds: the reference could not have stored it, and treating it as absent would unlock the fact.
enum FactUnlock: Equatable, Sendable {
  case condition(UnlockCondition)
  case unreadable
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:19 (FactLike) with the canon-fact columns the loaders read
struct DisclosureFact: Equatable, Sendable {
  var factKey: String
  var text: String
  var constraintNote: String?
  var writerNote: String?
  var terms: [String]?
  var allowedClues: [String]?
  var subjects: [String]?
  /// Nil for a source this version does not know: it is never `seed`, so the stricter rules apply.
  var source: FactSource?
  var disclosedInChapter: Int?
  var revealChapter: Int?
  var unlock: FactUnlock?

  init(
    factKey: String, text: String, constraintNote: String? = nil, writerNote: String? = nil, terms: [String]? = nil, allowedClues: [String]? = nil, subjects: [String]? = nil,
    source: FactSource? = nil, disclosedInChapter: Int? = nil, revealChapter: Int? = nil, unlock: FactUnlock? = nil
  ) {
    self.factKey = factKey
    self.text = text
    self.constraintNote = constraintNote
    self.writerNote = writerNote
    self.terms = terms
    self.allowedClues = allowedClues
    self.subjects = subjects
    self.source = source
    self.disclosedInChapter = disclosedInChapter
    self.revealChapter = revealChapter
    self.unlock = unlock
  }

  init(secret: SecretRecord, disclosedInChapter: Int?) {
    let unlock: FactUnlock? =
      switch secret.unlock {
      case nil, .null?: nil
      case let value?: UnlockCondition(validating: OrderedJSON(value)).map(FactUnlock.condition) ?? .unreadable
      }
    self.init(
      factKey: secret.secret, text: secret.text, constraintNote: secret.constraintNote, writerNote: secret.writerNote, terms: secret.cluesAndTerms?.terms,
      allowedClues: secret.cluesAndTerms?.clues, subjects: secret.subjects, source: secret.source.known, disclosedInChapter: disclosedInChapter,
      revealChapter: secret.revealChapter, unlock: unlock)
  }

  var hasUnlock: Bool { unlock != nil }
}

/// `revealRequirements` for a fact whose unlock may be unreadable; only whether the list is empty is ever read.
func disclosureRequirements(_ fact: DisclosureFact, _ context: UnlockContext) -> [String] {
  switch fact.unlock {
  case .unreadable?:
    return ["a readable unlock condition"]
  case .condition(let condition)?:
    return revealRequirements(RevealFact(factKey: fact.factKey, revealChapter: fact.revealChapter, unlock: condition, source: fact.source ?? .manual), context)
  case nil:
    return revealRequirements(RevealFact(factKey: fact.factKey, revealChapter: fact.revealChapter, unlock: nil, source: fact.source ?? .manual), context)
  }
}

func unlockHolds(_ fact: DisclosureFact, _ context: UnlockContext) -> Bool {
  switch fact.unlock {
  case nil: true
  case .unreadable?: false
  case .condition(let condition)?: evaluateUnlock(condition, context).holds
  }
}

// apps/novel-forge-server/src/database/schemas/knowledge.ts:43
enum KnowledgeStatus: String, Sendable {
  case provisional
  case committed
}

// apps/novel-forge-server/src/database/schemas/knowledge.ts:180, keyed by fact and entity key where the reference keys by row id
struct KnowledgeRow: Equatable, Sendable {
  var factKey: String
  var entityKey: String
  var learnedInChapter: Int
  var source: FactSource?
  var status: KnowledgeStatus
  var draftRevision: Int?

  init(factKey: String, entityKey: String, learnedInChapter: Int, source: FactSource?, status: KnowledgeStatus, draftRevision: Int? = nil) {
    self.factKey = factKey
    self.entityKey = entityKey
    self.learnedInChapter = learnedInChapter
    self.source = source
    self.status = status
    self.draftRevision = draftRevision
  }

  init(manual record: CharacterKnowledgeRecord) {
    self.init(factKey: record.fact, entityKey: record.entity, learnedInChapter: record.reveal.chapter, source: .manual, status: .committed)
  }

  var pair: LedgerPair { LedgerPair(factKey: factKey, entityKey: entityKey) }
}

struct LedgerPair: Hashable, Sendable {
  let factKey: String
  let entityKey: String

  static func == (left: LedgerPair, right: LedgerPair) -> Bool {
    left.factKey.jsEquals(right.factKey) && left.entityKey.jsEquals(right.entityKey)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(JSString(factKey))
    hasher.combine(JSString(entityKey))
  }
}

struct DisclosureEntity: Equatable, Sendable {
  var entityKey: String
  var name: String
}

struct DisclosureVolume: Equatable, Sendable {
  var volumeKey: String
  var ordinal: Int
  var title: String?
  var objective: String?
  var body: String?
}

// apps/novel-forge-server/src/common/plan-world.ts:20 (PlanOverlay); a stored plan carries the same columns
struct DisclosurePlan: Equatable, Sendable {
  var row: PlanRow
  var endingContract: OrderedJSON

  /// Keys exactly as given, for reference fixtures only: a plan read from records goes through `init(normalizing:...)`, or a decomposed key would name no fact.
  init(unnormalized row: PlanRow, endingContract: OrderedJSON) {
    self.row = row
    self.endingContract = endingContract
  }

  var claims: PlanClaims { row.claims }
}

extension DisclosurePlan {
  /// For a plan read from records, whose keys are NFC: the volume, claimed milestones, POV, learns and `mustNotResolve` keys are brought to NFC too, so a key typed in
  /// another form still names its record.
  init(normalizing claims: PlanClaims, knowledgeContract: OrderedJSON, endingContract: OrderedJSON) {
    var claims = claims
    claims.volumeKey = claims.volumeKey?.jsNormalize(.nfc)
    claims.claimedMilestones = claims.claimedMilestones?.map { $0.jsNormalize(.nfc) }
    let contract = mapMembers(knowledgeContract) { key, value in
      switch key {
      case "pov": mapItems(value, nfc)
      case "learns": mapItems(value) { learn in mapMembers(learn) { key, value in key == "entityKey" || key == "factKey" ? nfc(value) : value } }
      default: value
      }
    }
    let ending = mapMembers(endingContract) { key, value in key == "mustNotResolve" ? mapItems(value, nfc) : value }
    self.init(unnormalized: PlanRow(claims: claims, knowledgeContract: contract), endingContract: ending)
  }
}

private func nfc(_ value: OrderedJSON) -> OrderedJSON {
  guard case .string(let text) = value else { return value }
  return .string(text.jsNormalize(.nfc))
}

private func mapItems(_ value: OrderedJSON, _ transform: (OrderedJSON) -> OrderedJSON) -> OrderedJSON {
  guard case .array(let items) = value else { return value }
  return .array(items.map(transform))
}

private func mapMembers(_ value: OrderedJSON, _ transform: (String, OrderedJSON) -> OrderedJSON) -> OrderedJSON {
  guard case .object(let object) = value else { return value }
  return .object(OrderedJSONObject(object.entries.map { (key: $0.key, value: transform($0.key, $0.value)) }))
}

struct DisclosurePage: Equatable, Sendable {
  var address: BibleDocAddress
  var body: String
}

struct DraftRow: Equatable, Sendable {
  var chapter: Int
  var revision: Int
  var status: DraftStatus
  var reviewStatus: DraftReviewStatus
}

/// What the reference's loaders read from one project's tables, in table order. Facts and entities are the live ones; `knowledge` may still name a removed fact or
/// entity, and such a row counts for nothing, as a database row would have been deleted with its parent.
struct DisclosureWorld: Equatable, Sendable {
  var ending: String?
  var endingQuestion: String?
  var facts: [DisclosureFact]
  var entities: [DisclosureEntity]
  var knowledge: [KnowledgeRow]
  var plans: [DisclosurePlan]
  var milestones: [MilestoneRow]
  var volumes: [DisclosureVolume]
  var pages: [DisclosurePage]
  var drafts: [DraftRow]
  /// The reference's `knowledge.reader-knows-label` setting, off by default.
  var readerKnowsLabel: Bool

  init(
    ending: String? = nil, endingQuestion: String? = nil, facts: [DisclosureFact] = [], entities: [DisclosureEntity] = [], knowledge: [KnowledgeRow] = [],
    plans: [DisclosurePlan] = [],
    milestones: [MilestoneRow] = [], volumes: [DisclosureVolume] = [], pages: [DisclosurePage] = [], drafts: [DraftRow] = [], readerKnowsLabel: Bool = false
  ) {
    self.ending = ending
    self.endingQuestion = endingQuestion
    self.facts = facts
    self.entities = entities
    self.knowledge = knowledge
    self.plans = plans
    self.milestones = milestones
    self.volumes = volumes
    self.pages = pages
    self.drafts = drafts
    self.readerKnowsLabel = readerKnowsLabel
  }

  var volumeOrdinals: [JSString: Int] {
    var ordinals: [JSString: Int] = [:]
    for volume in volumes { ordinals[JSString(volume.volumeKey)] = volume.ordinal }
    return ordinals
  }

  var planWorld: PlanWorld {
    PlanWorld(plans: plans.map(\.row), milestones: milestones, volumeOrdinals: volumeOrdinals)
  }

  func storedPlan(for chapter: Int) -> DisclosurePlan? {
    plans.first { $0.claims.chapter == chapter }
  }

  var ledger: [KnowledgeRow] {
    let facts = Set(facts.map { JSString($0.factKey) })
    let entities = Set(entities.map { JSString($0.entityKey) })
    return knowledge.filter { facts.contains(JSString($0.factKey)) && entities.contains(JSString($0.entityKey)) }
  }
}
