// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:32
struct PovMember: Equatable, Sendable {
  let entityKey: String
  let name: String
}

struct LearnedChapter: Equatable, Sendable {
  let factKey: String
  let chapter: Int
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:38
struct KnowledgeView: Equatable, Sendable {
  var known: [DisclosureFact]
  var reveals: [DisclosureFact]
  var hidden: [DisclosureFact]
  var readerKnows: [DisclosureFact]
  var pooledPov: [PovMember]
  /// In the order the ledger first named each fact; nil when the project has no facts.
  var learnedIn: [LearnedChapter]?
}

struct KnowledgePartition: Equatable, Sendable {
  var known: [DisclosureFact]
  var reveals: [DisclosureFact]
  var hidden: [DisclosureFact]
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:84
func splitKnowledgeView(_ facts: [DisclosureFact], knownKeys: Set<JSString>, learnKeys: Set<JSString>) -> KnowledgePartition {
  var partition = KnowledgePartition(known: [], reveals: [], hidden: [])
  for fact in facts {
    let key = JSString(fact.factKey)
    if knownKeys.contains(key) {
      partition.known.append(fact)
    } else if learnKeys.contains(key) {
      partition.reveals.append(fact)
    } else {
      partition.hidden.append(fact)
    }
  }
  return partition
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:188
func mustNotResolveKeys(_ endingContract: OrderedJSON?) -> Set<JSString> {
  guard let entries = endingContract?.objectValue?["mustNotResolve"]?.arrayValue else { return [] }
  return Set(entries.compactMap(\.stringValue).map { JSString(($0.jsStartsWith("fact:") ? $0.jsSlice(5) : $0).jsTrim()) })
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:101 (loadKnowledgeView, which read the facts, the POV entities, the ledger and the plans)
func knowledgeView(in world: DisclosureWorld, chapter: Int, contract: KnowledgeContract, readerKnows: Bool? = nil, overlay: DisclosurePlan? = nil) -> KnowledgeView {
  let povKeys = contract.pov.jsUnique()
  let povSet = Set(povKeys.map { JSString($0) })
  let facts = world.facts
  let povEntities = world.entities.filter { povSet.contains(JSString($0.entityKey)) }
  let nameByKey = povEntities.jsLastByKey(\.entityKey)
  let pooledPov = povKeys.map { PovMember(entityKey: $0, name: nameByKey[JSString($0)]?.name ?? $0) }
  if facts.isEmpty { return KnowledgeView(known: [], reveals: [], hidden: [], readerKnows: [], pooledPov: pooledPov, learnedIn: nil) }

  var knownKeys = Set<JSString>()
  var learnedOrder: [JSString] = []
  var learnedIn: [JSString: LearnedChapter] = [:]
  if !povEntities.isEmpty {
    let povEntitySet = Set(povEntities.map { JSString($0.entityKey) })
    for row in world.ledger where povEntitySet.contains(JSString(row.entityKey)) && row.learnedInChapter < chapter {
      let key = JSString(row.factKey)
      knownKeys.insert(key)
      let previous = learnedIn[key]
      if previous == nil { learnedOrder.append(key) }
      learnedIn[key] = LearnedChapter(factKey: previous?.factKey ?? row.factKey, chapter: max(previous?.chapter ?? 0, row.learnedInChapter))
    }
  }

  var learnKeys = Set(contract.learns.map { JSString($0.factKey) })
  let learned = facts.filter { learnKeys.contains(JSString($0.factKey)) }
  if !learned.isEmpty {
    let context = chapterUnlockContext(world.planWorld, chapter: chapter, conditioned: learned.contains(where: \.hasUnlock), overlay: overlay?.claims)
    for fact in learned where !disclosureRequirements(fact, context).isEmpty { learnKeys.remove(JSString(fact.factKey)) }
  }
  for fact in facts where isOpenCanon(fact.revealChapter) && !fact.hasUnlock && !learnKeys.contains(JSString(fact.factKey)) { knownKeys.insert(JSString(fact.factKey)) }
  let partition = splitKnowledgeView(facts, knownKeys: knownKeys, learnKeys: learnKeys)
  let ledgered = learnedOrder.compactMap { learnedIn[$0] }
  let shownToReader = { (fact: DisclosureFact) in fact.disclosedInChapter.map { $0 < chapter } ?? false }
  guard readerKnows ?? world.readerKnowsLabel, partition.hidden.contains(where: shownToReader) else {
    return KnowledgeView(known: partition.known, reveals: partition.reveals, hidden: partition.hidden, readerKnows: [], pooledPov: pooledPov, learnedIn: ledgered)
  }

  let mustNotResolve = mustNotResolveKeys((overlay ?? world.storedPlan(for: chapter))?.endingContract)
  let labelled = { (fact: DisclosureFact) in shownToReader(fact) && !mustNotResolve.contains(JSString(fact.factKey)) }
  return KnowledgeView(
    known: partition.known, reveals: partition.reveals, hidden: partition.hidden.filter { !labelled($0) }, readerKnows: partition.hidden.filter(labelled), pooledPov: pooledPov,
    learnedIn: ledgered)
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:212 (writerVisibleFactKeys, which read the ledger and the plans)
func writerVisibleFactKeys(in world: DisclosureWorld, chapter: Int, facts: [DisclosureFact], contract: KnowledgeContract?, overlay: DisclosurePlan? = nil) -> Set<JSString> {
  if let contract {
    let view = knowledgeView(in: world, chapter: chapter, contract: contract, overlay: overlay)
    return Set((view.known + view.reveals + view.readerKnows).map { JSString($0.factKey) })
  }
  let unscheduled = Set(facts.filter { $0.revealChapter == nil }.map { JSString($0.factKey) })
  let revealedOnPage = Set(
    unscheduled.isEmpty
      ? [] : world.ledger.filter { $0.source == .brief && unscheduled.contains(JSString($0.factKey)) && $0.learnedInChapter < chapter }.map { JSString($0.factKey) })
  let context = chapterUnlockContext(world.planWorld, chapter: chapter, conditioned: facts.contains { $0.revealChapter != nil && $0.hasUnlock }, overlay: overlay?.claims)
  let visible = facts.filter { fact in
    guard let revealChapter = fact.revealChapter else { return revealedOnPage.contains(JSString(fact.factKey)) }
    return revealChapter <= chapter && unlockHolds(fact, context)
  }
  return Set(visible.map { JSString($0.factKey) })
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:200 (loadWriterHiddenFactKeys, which read the chapter's plan)
func writerHiddenFactKeys(in world: DisclosureWorld, chapter: Int, facts: [DisclosureFact], overlay: DisclosurePlan? = nil) -> Set<JSString> {
  let plan = overlay ?? world.storedPlan(for: chapter)
  let forbidden = mustNotResolveKeys(plan?.endingContract)
  let visible = writerVisibleFactKeys(in: world, chapter: chapter, facts: facts, contract: parseKnowledgeContract(plan?.row.knowledgeContract ?? .null), overlay: overlay)
  return Set(facts.map { JSString($0.factKey) }.filter { forbidden.contains($0) || !visible.contains($0) })
}

/// Code point order, which is PostgreSQL's `C` collation; the reference sorts by the database's collation.
func factKeyPrecedes(_ left: DisclosureFact, _ right: DisclosureFact) -> Bool {
  left.factKey.unicodeScalars.lexicographicallyPrecedes(right.factKey.unicodeScalars)
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:253 (loadWriterForbiddenFacts, which read the facts ordered by key)
func writerForbiddenFacts(in world: DisclosureWorld, chapter: Int, overlay: DisclosurePlan? = nil) -> [DisclosureFact] {
  let facts = world.facts.jsStableSorted(by: factKeyPrecedes)
  if facts.isEmpty { return [] }
  let hidden = writerHiddenFactKeys(in: world, chapter: chapter, facts: facts, overlay: overlay)
  return facts.filter { $0.source != .seed && hidden.contains(JSString($0.factKey)) }
}

struct FactWriterNote: Equatable, Sendable {
  let factKey: String
  let writerNote: String?
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:261 (loadFactWriterNotes, which read the facts)
func factWriterNotes(endingContract: OrderedJSON?, facts: [DisclosureFact]) -> [FactWriterNote] {
  guard let entries = endingContract?.objectValue?["mustNotResolve"]?.arrayValue, !entries.isEmpty else { return [] }
  return facts.jsMapValues(byKey: \.factKey).map { FactWriterNote(factKey: $0.factKey, writerNote: $0.writerNote) }
}
