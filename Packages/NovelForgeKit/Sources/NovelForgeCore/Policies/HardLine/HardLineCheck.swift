import ShadowCore

private let segmentBreak = builtInPattern(#"[.!?;\n]+|"\s*,\s*""#)

// apps/novel-forge-server/src/modules/ai/hard-line.ts:85
func findHardLine(_ texts: [String], scope: HardLineScope = .supplied, lexicon: HardLineLexicon = .standard) -> HardLineRule? {
  let pairing = scope == .supplied ? lexicon.sexual : lexicon.explicit
  for text in texts {
    if lexicon.standalone.contains(where: { $0.test(text) }) { return .standaloneTerm }
    for segment in text.jsSplit(segmentBreak) where lexicon.minor.contains(where: { $0.test(segment) }) && pairing.contains(where: { $0.test(segment) }) {
      return scope == .supplied ? .minorWithSexualContent : .minorWithExplicitAct
    }
  }
  return nil
}

// apps/novel-forge-server/src/modules/ai/hard-line.ts:98
func screenTexts(_ items: [ScreenedText], lexicon: HardLineLexicon = .standard) -> HardLineHit? {
  for item in items {
    if let rule = findHardLine([item.text], scope: item.scope, lexicon: lexicon) { return HardLineHit(rule: rule, source: item.source, sourceRefs: item.sourceRefs ?? []) }
  }
  return nil
}

// apps/novel-forge-server/src/modules/ai/hard-line.ts:106
func hardLineError(_ hit: HardLineHit) -> HardLineError {
  .declined(source: hit.source, rule: hit.rule, sourceRefs: hit.sourceRefs)
}

// apps/novel-forge-server/src/modules/ai/hard-line.ts:110
func isHardLineRefusal(_ error: (any Error)?) -> Bool {
  (error as? any ShadowError)?.code == "AI_015"
}
