struct SimileFrame: Sendable {
  let label: String
  let pattern: JSRegex
}

struct SimileFrameOveruse: Equatable, Sendable {
  let label: String
  let count: Int
  let per1000Words: Double
}

extension MechanicalCheck {
  static let simileFramePerThousandMax = 2.0
  static let simileFrameMinCount = 5

  // apps/novel-forge-server/src/modules/ai/graphs/mechanical-check.ts:60
  static let simileFrames: [SimileFrame] = [
    SimileFrame(
      label: "like a", pattern: ProseRegex.literal(#"(?<!\b(?:i|you|we|they|would|do|does|did|to|might|may|could|should|will|\w+n['’]t)\s)(?<!['’]d\s)\blike an?\b"#, "gi")),
    SimileFrame(label: "like she was", pattern: ProseRegex.literal(#"\blike (?:he|she|they|it)(?:['’]d)? (?:was|were|had|could|would|might)\b"#, "gi")),
    SimileFrame(label: "the way a", pattern: ProseRegex.literal(#"(?<!\b(?:on|by)\s)\bthe way (?:a|an|one|someone|somebody|people|you)\b"#, "gi")),
    SimileFrame(label: "the kind of", pattern: ProseRegex.literal(#"\bthe (?:kind|sort) of\b"#, "gi")),
  ]

  private static let dialogue = ProseRegex.literal(#"“[^”]*”|"[^"]*"|(?<=^|\s)‘.*?’(?!\p{L})"#, "gu")
  private static let openQuote = ProseRegex.literal(#"[“"]|(?<=^|\s)‘"#, "u")

  private static func withoutDialogue(_ paragraph: String) -> String {
    let unquoted = paragraph.jsReplace(dialogue, " ")
    let opening = unquoted.jsSearch(openQuote)
    return opening == -1 ? unquoted : unquoted.jsSlice(0, opening)
  }

  // apps/novel-forge-server/src/modules/ai/graphs/mechanical-check.ts:80
  static func findSimileFrameOveruse(_ body: String) -> [SimileFrameOveruse] {
    let words = ProseMetrics.countWords(body)
    if words == 0 { return [] }
    let narration = body.jsSplit(paragraphBreak).map(withoutDialogue).joined(separator: "\n\n")
    return simileFrames.map { frame in
      let count = narration.jsMatchAll(frame.pattern).count
      return SimileFrameOveruse(label: frame.label, count: count, per1000Words: Double(count) / Double(words) * 1000)
    }.filter { $0.count >= simileFrameMinCount && $0.per1000Words > simileFramePerThousandMax }
  }
}
