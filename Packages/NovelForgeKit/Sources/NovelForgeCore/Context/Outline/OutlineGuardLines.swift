import ShadowCore

private let revealScheduleBudget = 1_200
private let hardLimitBudget = 1_500
private let hardLimitChars = 400

struct OutlineGuardLines: Equatable, Sendable {
  var lines: [String]
  var omitted: Int
}

// apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:134
private func fitLines<Item>(_ items: [Item], budget: Int, render: (Item) -> String) -> (kept: [Item], lines: [String]) {
  var kept: [Item] = []
  var lines: [String] = []
  var used = 0
  for item in items {
    let line = render(item)
    let tokens = countTokens(line) + 1
    if used + tokens > budget { break }
    kept.append(item)
    lines.append(line)
    used += tokens
  }
  return (kept, lines)
}

private func termsNote(_ reveal: ScheduledReveal) -> String {
  reveal.terms.isEmpty ? "" : "; never name: \(reveal.terms.joined(separator: ", "))"
}

private func lockedLine(_ reveal: ScheduledReveal) -> String {
  let condition = reveal.unlock.map { "until \($0.all.map(describeUnlockTerm).joined(separator: " and "))" } ?? "with no reveal planned"
  return "\(reveal.factKey) — locked \(condition): hidden for this whole span\(termsNote(reveal))"
}

private func scheduleLine(_ reveal: ScheduledReveal, span: ChapterSpan) -> String {
  guard let chapter = reveal.revealChapter else { return lockedLine(reveal) }
  let rule = chapter > span.end ? "hidden for this whole span" : "nothing before ch \(chapter) may surface it"
  return "\(reveal.factKey) — reveals ch \(chapter): \(rule)\(termsNote(reveal))"
}

extension OutlineGuardLines {
  // apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:172 (renderRevealSchedule)
  static func revealSchedule(_ reveals: [ScheduledReveal], span: ChapterSpan) -> OutlineGuardLines {
    let candidates = reveals.filter { isRevealLocked($0, chapter: span.start) }
    let fitted = fitLines(candidates, budget: revealScheduleBudget) { scheduleLine($0, span: span) }
    return OutlineGuardLines(lines: fitted.lines, omitted: candidates.count - fitted.lines.count)
  }

  /// The power rules in key order; native has no world-fact records, so the world facts the reference adds are never present.
  // apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:196 (renderHardLimits)
  static func hardLimits(_ entities: [OutlineEntity]) -> OutlineGuardLines {
    let all =
      entities
      .filter { $0.type.jsEquals("power_rule") }
      .jsStableSorted { JSText.codeUnitPrecedes($0.entityKey, $1.entityKey) }
      .map { (entity: $0, rule: clipAtBoundary(nonEmpty($0.body?.jsTrim()) ?? nonEmpty($0.notes?.jsTrim()) ?? "", maxChars: hardLimitChars)) }
      .filter { !$0.rule.isEmpty }
      .map { "entity:\($0.entity.entityKey) — \($0.rule)" }
    let fitted = fitLines(all, budget: hardLimitBudget) { $0 }
    return OutlineGuardLines(lines: fitted.lines, omitted: all.count - fitted.lines.count)
  }
}

private func nonEmpty(_ text: String?) -> String? {
  guard let text, !text.isEmpty else { return nil }
  return text
}

extension UnlockCondition {
  // apps/novel-forge-server/src/common/unlock-condition.ts:74
  func shiftingChapters(after chapter: Int, by delta: Int = 1) -> UnlockCondition {
    UnlockCondition(
      all: all.map { term in
        guard case .chapter(let number) = term else { return term }
        return .chapter(number > chapter ? number + delta : number)
      })
  }
}

extension OutlineFact {
  /// Moves a reveal after `chapter` one chapter later, as a chapter insert will once it commits.
  // apps/novel-forge-server/src/modules/ai/context/canon-guard.ts:127 (shiftRevealsForInsert)
  func shiftingReveal(forInsertAfter chapter: Int) -> OutlineFact {
    guard let reveal = revealChapter, reveal > chapter else { return self }
    var shifted = self
    shifted.revealChapter = reveal + 1
    return shifted
  }
}
