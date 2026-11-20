import ShadowText

private let learnsField = "knowledgeContract.learns"
private let sentencePattern = ProseRegex.literal(#"[^.!?]+(?:[.!?]+["'”’)\]]*|$)\s*|[.!?]+\s*"#, "gu")
private let trailingSpace = ProseRegex.literal(#"\s*$"#, "u")

private struct Sanitiser {
  let subject: String
  let reveals: [ScheduledReveal]
  var sanitised: [RevealViolation] = []

  mutating func record(_ reveal: ScheduledReveal, field: String) {
    sanitised.append(RevealViolation(subject: subject, field: field, factKey: reveal.factKey, revealChapter: reveal.revealChapter))
  }
}

private func firstHit(_ text: String, _ reveals: [ScheduledReveal]) throws(DisclosureError) -> ScheduledReveal? {
  for reveal in reveals {
    for term in reveal.terms where try mentionsTerm(text, term) { return reveal }
  }
  return nil
}

private func placeholderFor(_ reveal: ScheduledReveal, _ reveals: [ScheduledReveal]) throws(DisclosureError) -> String {
  let candidates = reveal.revealChapter.map { ["(withheld until ch \($0))", "(withheld)"] } ?? ["(withheld)"]
  for candidate in candidates where try firstHit(candidate, reveals) == nil { return candidate }
  return "…"
}

private func cleanSentence(_ sentence: String, _ reveals: [ScheduledReveal], usedNotes: inout Set<JSString>) throws(DisclosureError) -> String {
  guard let hit = try firstHit(sentence, reveals) else { return sentence }
  guard let note = hit.writerNote, !note.isEmpty, try firstHit(note, reveals) == nil, usedNotes.insert(JSString(note)).inserted else { return "" }
  return note + (trailingSpace.exec(sentence)?.text ?? "")
}

private func sanitiseText(_ text: String, field: String, state: inout Sanitiser) throws(DisclosureError) -> String {
  guard let hit = try firstHit(text, state.reveals) else { return text }
  state.record(hit, field: field)
  var usedNotes = Set<JSString>()
  let matches = text.jsMatchAll(sentencePattern).map(\.text)
  var cleaned = ""
  for sentence in matches.isEmpty ? [text] : matches { cleaned += try cleanSentence(sentence, state.reveals, usedNotes: &usedNotes) }
  cleaned = cleaned.jsTrim()
  if !cleaned.isEmpty, try firstHit(cleaned, state.reveals) == nil { return cleaned }
  return try placeholderFor(hit, state.reveals)
}

private func sanitiseOptional(_ text: String?, field: String, state: inout Sanitiser) throws(DisclosureError) -> String? {
  guard let text else { return nil }
  return try sanitiseText(text, field: field, state: &state)
}

private func sanitiseList(_ items: [String], field: String, state: inout Sanitiser) throws(DisclosureError) -> [String] {
  var kept: [String] = []
  for (index, item) in items.enumerated() {
    if let hit = try firstHit(item, state.reveals) {
      state.record(hit, field: "\(field)[\(index)]")
    } else {
      kept.append(item)
    }
  }
  return kept
}

private func sanitiseScene(_ scene: BriefScene, path: String, state: inout Sanitiser, placeholder: String) throws(DisclosureError) -> BriefScene {
  var safe = scene
  var beats: [String]?
  if let original = scene.beats { beats = try sanitiseList(original, field: "\(path).beats", state: &state) }
  safe.summary = try sanitiseText(scene.summary, field: "\(path).summary", state: &state)
  safe.goal = try sanitiseOptional(scene.goal, field: "\(path).goal", state: &state)
  safe.obstacle = try sanitiseOptional(scene.obstacle, field: "\(path).obstacle", state: &state)
  safe.turn = try sanitiseOptional(scene.turn, field: "\(path).turn", state: &state)
  safe.beats = beats.map { $0.isEmpty ? [placeholder] : $0 }
  return safe
}

private func lockedReveals(_ reveals: [ScheduledReveal], chapter: Int) -> [ScheduledReveal] {
  reveals.filter { isRevealLocked($0, chapter: chapter) }
}

// apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:344
func sanitiseBriefReveals(_ brief: PlannedChapter, chapter: Int, reveals: [ScheduledReveal]) throws(DisclosureError) -> (brief: PlannedChapter, sanitised: [RevealViolation]) {
  var state = Sanitiser(subject: "chapter \(chapter)", reveals: lockedReveals(reveals, chapter: chapter))
  guard let firstReveal = state.reveals.first else { return (brief, []) }
  let early = Set(state.reveals.map { JSString($0.factKey) })
  let learns = brief.knowledgeContract?.learns
  for entry in learns ?? [] {
    if let reveal = state.reveals.first(where: { $0.factKey.jsEquals(entry.factKey) }) { state.record(reveal, field: learnsField) }
  }
  var safe = brief
  let placeholder = try placeholderFor(firstReveal, state.reveals)
  safe.title = try sanitiseText(brief.title, field: "title", state: &state)
  safe.objective = try sanitiseText(brief.objective, field: "objective", state: &state)
  safe.scenes = []
  for (index, scene) in brief.scenes.enumerated() { safe.scenes.append(try sanitiseScene(scene, path: "scenes[\(index)]", state: &state, placeholder: placeholder)) }
  safe.chapterPurpose = try sanitiseText(brief.chapterPurpose, field: "chapterPurpose", state: &state)
  safe.handoffBeat = try sanitiseOptional(brief.handoffBeat, field: "handoffBeat", state: &state)
  if let risks = brief.repetitionRisks { safe.repetitionRisks = try sanitiseList(risks, field: "repetitionRisks", state: &state) }
  safe.endingContract.emotionalBeat = try sanitiseText(brief.endingContract.emotionalBeat, field: "endingContract.emotionalBeat", state: &state)
  safe.endingContract.openQuestion = try sanitiseText(brief.endingContract.openQuestion, field: "endingContract.openQuestion", state: &state)
  safe.endingContract.handoffState = try sanitiseText(brief.endingContract.handoffState, field: "endingContract.handoffState", state: &state)
  if let entries = brief.endingContract.mustNotResolve {
    safe.endingContract.mustNotResolve = try sanitiseList(entries, field: "endingContract.mustNotResolve", state: &state)
  }
  if let learns { safe.knowledgeContract?.learns = learns.filter { !early.contains(JSString($0.factKey)) } }
  return (safe, state.sanitised)
}

func sanitiseRevealText(_ text: String, chapter: Int, reveals: [ScheduledReveal]) throws(DisclosureError) -> String {
  var state = Sanitiser(subject: "chapter \(chapter)", reveals: lockedReveals(reveals, chapter: chapter))
  guard !state.reveals.isEmpty else { return text }
  return try sanitiseText(text, field: "objective", state: &state)
}
