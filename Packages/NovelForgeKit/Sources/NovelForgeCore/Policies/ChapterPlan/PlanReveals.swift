import ShadowText

private let learnsField = "knowledgeContract.learns"

struct ScheduledReveal: Equatable, Sendable {
  var factKey: String
  var revealChapter: Int?
  var terms: [String]
  var writerNote: String?
  var unlock: UnlockCondition?
}

struct RevealViolation: Equatable, Sendable {
  var subject: String
  var field: String
  var factKey: String
  var revealChapter: Int?
}

// apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:82
func isRevealLocked(_ reveal: ScheduledReveal, chapter: Int) -> Bool {
  reveal.revealChapter.map { $0 > chapter } ?? true
}

private func byRevealChapter(_ left: ScheduledReveal, _ right: ScheduledReveal) -> Bool {
  switch (left.revealChapter, right.revealChapter) {
  case (let a?, let b?) where a != b: a < b
  case (nil, _?): false
  case (_?, nil): true
  default: JSText.codeUnitPrecedes(left.factKey, right.factKey)
  }
}

// apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:98
func scheduledReveals(_ facts: [PlanFact], unlockHolds: (UnlockCondition) -> Bool = { _ in false }) -> [ScheduledReveal] {
  let reveals = facts.compactMap { fact -> ScheduledReveal? in
    if fact.source == .seed && fact.unlock == nil { return nil }
    let locked = fact.unlock.map { !unlockHolds($0) } ?? (fact.revealChapter == nil)
    if !locked && fact.revealChapter == nil { return nil }
    let terms = fact.terms.filter { !$0.jsTrim().isEmpty }
    let note = fact.writerNote?.jsTrim()
    return ScheduledReveal(
      factKey: fact.factKey, revealChapter: locked ? nil : fact.revealChapter, terms: terms, writerNote: note?.isEmpty == false ? note : nil, unlock: fact.unlock)
  }
  return reveals.jsStableSorted(by: byRevealChapter)
}

func mentionsTerm(_ text: String, _ term: String) throws(DisclosureError) -> Bool {
  try revealTermPattern(term)?.test(text) ?? false
}

// apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:221
func renderRevealViolation(_ violation: RevealViolation) -> String {
  let (subject, field, factKey) = (violation.subject, violation.field, violation.factKey)
  guard let chapter = violation.revealChapter else {
    let locked = "which stays locked for this whole span"
    if field == learnsField { return "\(subject) \(learnsField) names \(factKey), \(locked) — leave the discovery out" }
    return "\(subject) \(field) names a REVEAL SCHEDULE term of \(factKey), \(locked) — keep it out"
  }
  let schedule = "whose reveal is scheduled for chapter \(chapter)"
  if field == learnsField { return "\(subject) \(learnsField) names \(factKey), \(schedule) — move the discovery there" }
  return "\(subject) \(field) names a REVEAL SCHEDULE term of \(factKey), \(schedule) — keep it out until then"
}

private func sceneFields(_ scene: BriefScene, _ index: Int) -> [(String, String?)] {
  let path = "scenes[\(index)]"
  return [("\(path).summary", scene.summary), ("\(path).goal", scene.goal), ("\(path).obstacle", scene.obstacle), ("\(path).turn", scene.turn)]
    + (scene.beats ?? []).enumerated().map { ("\(path).beats[\($0.offset)]", $0.element) }
}

private func briefFields(_ brief: PlannedChapter) -> [(String, String?)] {
  let ending = brief.endingContract
  return [("title", brief.title), ("objective", brief.objective)]
    + brief.scenes.enumerated().flatMap { sceneFields($0.element, $0.offset) }
    + [("chapterPurpose", brief.chapterPurpose), ("handoffBeat", brief.handoffBeat)]
    + [("endingContract.emotionalBeat", ending.emotionalBeat), ("endingContract.openQuestion", ending.openQuestion), ("endingContract.handoffState", ending.handoffState)]
    + (ending.mustNotResolve ?? []).enumerated().map { ("endingContract.mustNotResolve[\($0.offset)]", $0.element) }
    + (brief.repetitionRisks ?? []).enumerated().map { ("repetitionRisks[\($0.offset)]", $0.element) }
}

private func firstMentioningField(_ fields: [(String, String?)], _ reveal: ScheduledReveal) throws(DisclosureError) -> String? {
  for (field, text) in fields {
    guard let text, !text.isEmpty else { continue }
    for term in reveal.terms where try mentionsTerm(text, term) { return field }
  }
  return nil
}

// apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:244
func findBriefRevealViolations(_ brief: PlannedChapter, chapter: Int, reveals: [ScheduledReveal]) throws(DisclosureError) -> [RevealViolation] {
  let subject = "chapter \(chapter)"
  let learned = Set((brief.knowledgeContract?.learns ?? []).map { JSString($0.factKey) })
  let fields = briefFields(brief)
  var violations: [RevealViolation] = []
  for reveal in reveals where isRevealLocked(reveal, chapter: chapter) {
    let field = learned.contains(JSString(reveal.factKey)) ? learnsField : try firstMentioningField(fields, reveal)
    guard let field else { continue }
    violations.append(RevealViolation(subject: subject, field: field, factKey: reveal.factKey, revealChapter: reveal.revealChapter))
  }
  return violations
}
