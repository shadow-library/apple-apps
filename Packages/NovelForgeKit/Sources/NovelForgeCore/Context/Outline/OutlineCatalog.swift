import ShadowCore

private let chapterCap = 50
private let entityCap = 150
private let richDescriptorChars = 600
private let shortDescriptorChars = 100
private let entityBudget = 9_000
private let documentBudget = 3_000
private let documentExcerptChars = 160

// apps/novel-forge-server/src/modules/ai/context/catalog.service.ts:49 (CatalogOptions)
struct OutlineCatalogOptions: Equatable, Sendable {
  var maxTokens: Int?
  var span: ChapterSpan?
  var insertAfter: Int?
}

private enum PartKey: String {
  case chapters
  case volumes
  case entities
  case threads
  case mysteries
  case canonFacts = "canon_facts"
  case documents
  case revealSchedule = "reveal_schedule"
  case hardLimits = "hard_limits"
}

private enum TrimFrom {
  case start
  case end
}

private struct Part {
  var key: PartKey
  var header: String
  var lines: [String]
  var trimFrom: TrimFrom
  var omittedLabel: String
  var omitted: Int
}

// World facts, which the reference trims first, have no vault record, so the order starts at the chapters.
// apps/novel-forge-server/src/modules/ai/context/catalog.service.ts:67
private let trimOrder: [PartKey] = [.chapters, .mysteries, .threads, .documents, .canonFacts, .hardLimits, .entities]

private func byKey(_ left: String, _ right: String) -> Int {
  JSText.codeUnitPrecedes(left, right) ? -1 : JSText.codeUnitPrecedes(right, left) ? 1 : 0
}

private func descriptorSource(_ entity: OutlineEntity) -> String {
  if let body = entity.body?.jsTrim(), !body.isEmpty { return body }
  if let notes = entity.notes?.jsTrim(), !notes.isEmpty { return notes }
  return ""
}

private func entityLine(_ entity: OutlineEntity, maxChars: Int) -> String {
  "\(entity.entityKey) — \(entity.type): \(clipAtBoundary(descriptorSource(entity), maxChars: maxChars)) (\(entity.status ?? "active"))"
}

private func renderEntityLines(_ ranked: [OutlineEntity]) -> [String] {
  var lines = ranked.map { entityLine($0, maxChars: shortDescriptorChars) }
  var used = lines.reduce(0) { $0 + countTokens($1) + 1 }
  for (index, entity) in ranked.enumerated() {
    let rich = entityLine(entity, maxChars: richDescriptorChars)
    let current = lines[index]
    if rich.jsEquals(current) { continue }
    let delta = countTokens(rich) - countTokens(current)
    if used + delta > entityBudget { continue }
    lines[index] = rich
    used += delta
  }
  return lines
}

private func renderDocumentLines(_ documents: [OutlineDocument]) -> (lines: [String], omitted: Int) {
  var lines: [String] = []
  let ranked = OutlineDocument.ranked(documents.filter { $0.hasContent && !isPlannerOnlyBibleDoc($0.address) })
  var used = 0
  for document in ranked {
    let label = document.label
    let excerpt = bibleDocExcerpt(body: document.body, maxChars: documentExcerptChars)
    let line = "\(document.ref) — \(label)\(!excerpt.isEmpty && !excerpt.jsEquals(label) ? ": \(excerpt)" : "")"
    let tokens = countTokens(line) + 1
    if used + tokens > documentBudget { break }
    lines.append(line)
    used += tokens
  }
  return (lines, ranked.count - lines.count)
}

private func renderPart(_ part: Part) -> String {
  let note = part.omitted > 0 ? ["(+\(part.omitted) \(part.omittedLabel) omitted)"] : []
  return ([part.header] + note + part.lines).joined(separator: "\n")
}

private func renderParts(_ parts: [Part]) -> String {
  parts.map(renderPart).joined(separator: "\n\n")
}

// apps/novel-forge-server/src/modules/ai/context/catalog.service.ts:128
private func trimToCeiling(_ parts: inout [Part], maxTokens: Int) {
  for _ in 0..<3 {
    for key in trimOrder {
      var over = countTokens(renderParts(parts)) - maxTokens
      if over <= 0 { return }
      guard let index = parts.firstIndex(where: { $0.key == key }) else { continue }
      while over > 0 && !parts[index].lines.isEmpty {
        let line = parts[index].trimFrom == .start ? parts[index].lines.removeFirst() : parts[index].lines.removeLast()
        parts[index].omitted += 1
        over -= countTokens(line) + 1
      }
    }
  }
}

private func padded(_ ordinal: Int) -> String {
  let text = String(ordinal)
  return text.count >= 2 ? text : String(repeating: "0", count: 2 - text.count) + text
}

private func lastMoved(_ promise: OutlinePromise) -> Int {
  promise.lastAdvancedChapter ?? promise.openedChapter ?? 0
}

private func factPriority(_ fact: OutlineFact) -> Int {
  if fact.revealed { return 2 }
  return fact.revealChapter != nil ? 0 : 1
}

extension OutlineWorld {
  /// Every canon fact, including the hidden ones, in full: safe because the catalog reaches planning contexts and never the chapter writer's pack.
  // apps/novel-forge-server/src/modules/ai/context/catalog.service.ts:182 (CatalogService.render)
  func catalog(_ options: OutlineCatalogOptions) -> String {
    let facts = options.insertAfter.map { after in self.facts.map { $0.shiftingReveal(forInsertAfter: after) } } ?? self.facts
    var parts: [Part] = []
    func part(_ key: PartKey, _ header: String, _ lines: [String], _ omittedLabel: String, omitted: Int = 0, trimFrom: TrimFrom = .end) {
      if !lines.isEmpty || omitted > 0 { parts.append(Part(key: key, header: header, lines: lines, trimFrom: trimFrom, omittedLabel: omittedLabel, omitted: omitted)) }
    }

    let sortedChapters = chapters.jsStableSorted { $0.number < $1.number }
    let shownChapters = Array(sortedChapters.suffix(chapterCap))
    let chapterLines = shownChapters.map { chapter -> String in
      let tag = chapter.isolated ? " [unrestricted]" : ""
      let suffix = !chapter.isolated && chapter.summary.map { !$0.isEmpty && $0.jsLength <= 60 } == true ? " (\(chapter.summary ?? ""))" : ""
      let title = (!chapter.isolated ? chapter.title.flatMap { $0.isEmpty ? nil : $0 } : nil) ?? "Chapter \(chapter.number)"
      return "\(chapter.number) — \(title)\(tag)\(suffix)"
    }
    part(.chapters, "CHAPTERS:", chapterLines, "earlier chapters", omitted: sortedChapters.count - shownChapters.count, trimFrom: .start)

    let volumeLines = volumes.jsStableSorted { $0.ordinal != $1.ordinal ? $0.ordinal < $1.ordinal : byKey($0.volumeKey, $1.volumeKey) < 0 }
      .map { "v\(padded($0.ordinal)) — \($0.title ?? $0.volumeKey)" }
    part(.volumes, "VOLUMES:", volumeLines, "volumes")

    let rankedEntities = entities.jsStableSorted { left, right in
      let (a, b) = (left.isMajor ? 0 : 1, right.isMajor ? 0 : 1)
      return a != b ? a < b : byKey(left.entityKey, right.entityKey) < 0
    }
    part(.entities, "ENTITIES:", renderEntityLines(Array(rankedEntities.prefix(entityCap))), "minor entities", omitted: max(0, rankedEntities.count - entityCap))

    let threadLines = openLines(threads) { "\($0.key) — \($0.text ?? "") (open since ch \($0.openedChapter.map(String.init) ?? "?"))" }
    part(.threads, "OPEN PLOT THREADS:", threadLines, "less recently advanced threads")

    let mysteryLines = openLines(mysteries) { "\($0.key) — open: \($0.text ?? "") (ch \($0.openedChapter.map(String.init) ?? "?"))" }
    part(.mysteries, "UNRESOLVED MYSTERIES:", mysteryLines, "less recently advanced mysteries")

    let newline = ProseRegex.literal(#"\n"#, "g")
    let factLines = facts.jsStableSorted { left, right in
      let (a, b) = (factPriority(left), factPriority(right))
      if a != b { return a < b }
      let (x, y) = (left.revealChapter ?? 0, right.revealChapter ?? 0)
      return x != y ? x < y : byKey(left.factKey, right.factKey) < 0
    }
    .map { fact -> String in
      let text = fact.text.jsReplace(newline, " ").jsSlice(0, 160)
      let status = fact.revealed ? " (revealed)" : fact.revealChapter.map { " (unrevealed; scheduled ch \($0))" } ?? " (unrevealed)"
      return "\(fact.factKey): \(text)\(status)"
    }
    part(.canonFacts, "CANON FACTS:", factLines, "lower-priority canon facts")

    let documentLines = renderDocumentLines(documents)
    part(.documents, "BIBLE DOCUMENTS (cite with the ref exactly as written):", documentLines.lines, "lower-priority documents", omitted: documentLines.omitted)

    if let span = options.span {
      let unlockHolds = unlockHolds(span: span, insertAfter: options.insertAfter, facts: facts)
      let schedule = OutlineGuardLines.revealSchedule(scheduledReveals(facts.map(\.planFact), unlockHolds: unlockHolds), span: span)
      part(.revealSchedule, "REVEAL SCHEDULE (binding for chapters \(span.start)–\(span.end)):", schedule.lines, "later reveals", omitted: schedule.omitted)
      let limits = OutlineGuardLines.hardLimits(entities)
      part(.hardLimits, "HARD LIMITS (no planned event may break these):", limits.lines, "further limits", omitted: limits.omitted)
    }

    if let maxTokens = options.maxTokens { trimToCeiling(&parts, maxTokens: maxTokens) }
    return renderParts(parts)
  }

  private func openLines(_ promises: [OutlinePromise], render: (OutlinePromise) -> String) -> [String] {
    promises.filter(\.isOpen)
      .jsStableSorted { left, right in
        let (a, b) = (lastMoved(left), lastMoved(right))
        return a != b ? a > b : byKey(left.key, right.key) < 0
      }
      .map(render)
  }

  /// A condition is judged for a plan at the span's first chapter that claims nothing and is not the ending, which is what a planned slot knows before the author confirms its claims.
  // apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:150 (spanUnlockHolds)
  private func unlockHolds(span: ChapterSpan, insertAfter: Int?, facts: [OutlineFact]) -> (UnlockCondition) -> Bool {
    guard facts.contains(where: { $0.unlock != nil }) else { return { _ in false } }
    let volumeKey = nearestVolumeKey(planWorld.plans.map(\.claims), chapter: span.start - 1)
    let context = planUnlockContext(PlanClaims(chapter: span.start, volumeKey: volumeKey, isEnding: false, claimedMilestones: []), planWorld)
    return { unlock in evaluateUnlock(insertAfter.map { unlock.shiftingChapters(after: $0) } ?? unlock, context).holds }
  }
}
