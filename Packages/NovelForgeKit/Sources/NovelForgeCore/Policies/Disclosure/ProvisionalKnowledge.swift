// apps/novel-forge-server/src/common/provisional-knowledge.ts:23
struct ResolvedBriefReveals: Equatable, Sendable {
  var pairs: [LedgerPair]
  var factKeys: [String]
  var skipped: [String]
  var locked: [String]
}

struct LedgerOutcome: Equatable, Sendable {
  let applied: Int
  let skipped: [String]
}

extension DisclosureWorld {
  // apps/novel-forge-server/src/common/provisional-knowledge.ts:49 (resolveBriefReveals, which read the chapter's stored plan, its facts and entities)
  /// `contexts`, when given, is `plannedUnlockContexts` of this world computed once by a caller that resolves many chapters.
  func resolveBriefReveals(chapter: Int, contexts: ((Int) -> UnlockContext)? = nil) -> ResolvedBriefReveals {
    guard let contract = parseKnowledgeContract(storedPlan(for: chapter)?.row.knowledgeContract ?? .null), !contract.learns.isEmpty else {
      return ResolvedBriefReveals(pairs: [], factKeys: [], skipped: [], locked: [])
    }
    let factKeys = Set(contract.learns.map { JSString($0.factKey) })
    let entityKeys = Set(contract.learns.map { JSString($0.entityKey) })
    let facts = self.facts.filter { factKeys.contains(JSString($0.factKey)) }
    let entities = self.entities.filter { entityKeys.contains(JSString($0.entityKey)) }
    let conditioned = facts.contains(where: \.hasUnlock)
    let context = (conditioned ? contexts : nil)?(chapter) ?? plannedUnlockContexts(planWorld, conditioned: conditioned)(chapter)
    let lockedFacts = facts.filter { !disclosureRequirements($0, context).isEmpty }.jsMapValues(byKey: \.factKey)
    let locked = Set(lockedFacts.map { JSString($0.factKey) })
    let resolvedFacts = facts.filter { !locked.contains(JSString($0.factKey)) }.jsMapValues(byKey: \.factKey)
    let resolvedFactKeys = Set(resolvedFacts.map { JSString($0.factKey) })
    let entityByKey = entities.jsLastByKey(\.entityKey)

    var skipped: [String] = []
    var pairs: [LedgerPair] = []
    var seenPairs = Set<LedgerPair>()
    for reveal in contract.learns where !locked.contains(JSString(reveal.factKey)) {
      guard resolvedFactKeys.contains(JSString(reveal.factKey)), let entity = entityByKey[JSString(reveal.entityKey)] else {
        skipped.append("\(reveal.entityKey)→\(reveal.factKey)")
        continue
      }
      let pair = LedgerPair(factKey: reveal.factKey, entityKey: entity.entityKey)
      if seenPairs.insert(pair).inserted { pairs.append(pair) }
    }
    return ResolvedBriefReveals(pairs: pairs, factKeys: resolvedFacts.map(\.factKey), skipped: skipped, locked: lockedFacts.map(\.factKey))
  }

  // apps/novel-forge-server/src/common/provisional-knowledge.ts:144 (datedReveals, which read the undisclosed facts dated at or before the chapter)
  func datedReveals(chapter: Int) -> [String] {
    let dated = facts.filter { fact in
      guard let revealChapter = fact.revealChapter else { return false }
      return revealChapter <= chapter && fact.disclosedInChapter == nil && !isOpenCanon(revealChapter)
    }
    if dated.isEmpty { return [] }
    let contextAt = plannedUnlockContexts(planWorld, conditioned: dated.contains(where: \.hasUnlock))
    let holdsAt = { (fact: DisclosureFact, at: Int) in disclosureRequirements(fact, contextAt(at)).isEmpty }
    return dated.filter { holdsAt($0, chapter) && !holdsAt($0, chapter - 1) }.map(\.factKey)
  }

  // apps/novel-forge-server/src/common/provisional-knowledge.ts:130 without its write: the facts the chapter shows the reader, already disclosed ones included
  // when its plan has a contract
  func chapterReveals(chapter: Int) -> [String] {
    guard let plan = storedPlan(for: chapter) else { return [] }
    guard parseKnowledgeContract(plan.row.knowledgeContract) != nil else { return datedReveals(chapter: chapter) }
    return resolveBriefReveals(chapter: chapter).factKeys
  }

  // apps/novel-forge-server/src/common/provisional-knowledge.ts:130
  mutating func discloseChapterReveals(chapter: Int) {
    let disclosed = Set(chapterReveals(chapter: chapter).map { JSString($0) })
    for index in facts.indices where facts[index].disclosedInChapter == nil && disclosed.contains(JSString(facts[index].factKey)) { facts[index].disclosedInChapter = chapter }
  }

  // apps/novel-forge-server/src/common/provisional-knowledge.ts:36; a row for a pair already held changes only when it came from a plan and the new chapter is earlier
  mutating func writeBriefReveals(_ rows: [KnowledgeRow]) {
    for row in rows {
      guard let index = knowledge.firstIndex(where: { $0.pair == row.pair }) else {
        knowledge.append(row)
        continue
      }
      guard knowledge[index].source == .brief, row.learnedInChapter < knowledge[index].learnedInChapter else { continue }
      knowledge[index].learnedInChapter = row.learnedInChapter
      knowledge[index].status = row.status
      knowledge[index].draftRevision = row.draftRevision
    }
  }

  // apps/novel-forge-server/src/common/provisional-knowledge.ts:88
  @discardableResult
  mutating func ledgerBriefReveals(chapter: Int, draftRevision: Int, contexts: ((Int) -> UnlockContext)? = nil) -> LedgerOutcome {
    revokeProvisionalReveals(chapters: [chapter])
    let resolved = resolveBriefReveals(chapter: chapter, contexts: contexts)
    writeBriefReveals(
      resolved.pairs.map {
        KnowledgeRow(factKey: $0.factKey, entityKey: $0.entityKey, learnedInChapter: chapter, source: .brief, status: .provisional, draftRevision: draftRevision)
      })
    return LedgerOutcome(applied: resolved.pairs.count, skipped: resolved.skipped)
  }

  /// Character events, which the reference revokes here too, are not part of this port.
  // apps/novel-forge-server/src/common/provisional-knowledge.ts:105
  mutating func revokeProvisionalReveals(chapters: [Int]) {
    if chapters.isEmpty { return }
    let revoked = Set(chapters)
    let deleted = ledger.filter { $0.source == .brief && revoked.contains($0.learnedInChapter) }
    knowledge.removeAll { $0.source == .brief && revoked.contains($0.learnedInChapter) }
    if !deleted.isEmpty { writeBriefReveals(remainingClaims(revoked: revoked, deleted: deleted.map(\.pair))) }
  }

  // apps/novel-forge-server/src/common/provisional-knowledge.ts:163
  mutating func commitChapterKnowledge(chapter: Int, draftRevision: Int) {
    commitProvisionalRows(chapter: chapter, draftRevision: draftRevision)
    discloseChapterReveals(chapter: chapter)
  }

  mutating func commitProvisionalRows(chapter: Int, draftRevision: Int) {
    let provisional = { (row: KnowledgeRow) in row.source == .brief && row.learnedInChapter == chapter && row.status == .provisional }
    for index in knowledge.indices where provisional(knowledge[index]) && knowledge[index].draftRevision == draftRevision { knowledge[index].status = .committed }
    knowledge.removeAll(where: provisional)
  }

  // apps/novel-forge-server/src/common/provisional-knowledge.ts:183 (reledgerRemainingClaims, which read the revoked pairs' facts and entities and the approved or final drafts)
  private func remainingClaims(revoked: Set<Int>, deleted: [LedgerPair]) -> [KnowledgeRow] {
    let deletedFacts = Set(deleted.map { JSString($0.factKey) })
    let deletedEntities = Set(deleted.map { JSString($0.entityKey) })
    let facts = self.facts.filter { deletedFacts.contains(JSString($0.factKey)) }
    let entities = self.entities.filter { deletedEntities.contains(JSString($0.entityKey)) }
    let claimants = drafts.filter { ($0.reviewStatus == .approved || $0.status == .final) && !revoked.contains($0.chapter) }
    if claimants.isEmpty { return [] }
    let claimantChapters = Set(claimants.map(\.chapter))
    let plans = plans.filter { claimantChapters.contains($0.claims.chapter) }.jsStableSorted { $0.claims.chapter < $1.claims.chapter }
    let wanted = Set(deleted)
    var claimantByChapter: [Int: DraftRow] = [:]
    for claimant in claimants { claimantByChapter[claimant.chapter] = claimant }
    let factByKey = facts.jsLastByKey(\.factKey)
    let entityByKey = entities.jsLastByKey(\.entityKey)
    let contextAt = plannedUnlockContexts(planWorld, conditioned: facts.contains(where: \.hasUnlock))

    var earliest: [KnowledgeRow] = []
    var claimed = Set<LedgerPair>()
    for plan in plans {
      let claimant = claimantByChapter[plan.claims.chapter]
      for reveal in parseKnowledgeContract(plan.row.knowledgeContract)?.learns ?? [] {
        let fact = factByKey[JSString(reveal.factKey)].flatMap { disclosureRequirements($0, contextAt(plan.claims.chapter)).isEmpty ? $0 : nil }
        guard let claimant, let fact, let entity = entityByKey[JSString(reveal.entityKey)] else { continue }
        let pair = LedgerPair(factKey: fact.factKey, entityKey: entity.entityKey)
        guard wanted.contains(pair), claimed.insert(pair).inserted else { continue }
        earliest.append(
          KnowledgeRow(
            factKey: fact.factKey, entityKey: entity.entityKey, learnedInChapter: plan.claims.chapter, source: .brief,
            status: claimant.status == .final ? .committed : .provisional,
            draftRevision: claimant.revision))
      }
    }
    return earliest
  }
}
