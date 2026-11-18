struct WriterVolumeChapter: Equatable, Sendable {
  var number: Int
  var summary: String
}

// apps/novel-forge-server/src/modules/ai/context/writer-context.ts:100
struct WriterCompletedVolume: Equatable, Sendable {
  var ordinal: Int
  var title: String
  var goal: String?
  var chapters: [WriterVolumeChapter]
}

private let volumeBlockCap = 400
private let goalCap = 50
private let turnCap = 50
private let closingCap = 120
private let lateTurns = 2
private let spaceRun = ProseRegex.literal(" +")
private let sentenceEnd = ProseRegex.literal(#"(?<=[.!?。！？])\s+"#, "u")

extension WriterRender {
  // writer-context.ts:119
  private static func leadingWords(_ text: String, maxTokens: Int) -> String {
    if countTokens(text) <= maxTokens { return text }
    let words = text.jsSplit(spaceRun)
    var fits = 0
    var over = words.count
    while over - fits > 1 {
      let middle = (fits + over) / 2
      if countTokens(words.prefix(middle).joined(separator: " ")) < maxTokens {
        fits = middle
      } else {
        over = middle
      }
    }
    let head = fits == 0 ? leadingChars(words.first ?? "", maxTokens: maxTokens - 1) : words.prefix(fits).joined(separator: " ")
    return head + "…"
  }

  // writer-context.ts:132
  private static func capped(_ text: String, maxTokens: Int) -> String {
    leadingWords(text.jsReplace(ProseRegex.whitespaceRunGlobal, " ").jsTrim(), maxTokens: maxTokens)
  }

  // writer-context.ts:138
  private static func firstSentence(_ summary: String, scrub: (String) throws(DisclosureError) -> String) throws(DisclosureError) -> String {
    capped(try scrub(summary).jsSplit(sentenceEnd, limit: 1).first ?? "", maxTokens: turnCap)
  }

  // writer-context.ts:142
  private static func volumeBlock(_ volume: WriterCompletedVolume, scrub: (String) throws(DisclosureError) -> String) throws(DisclosureError) -> String? {
    guard let first = volume.chapters.first, let last = volume.chapters.last else { return nil }
    let span = first.number == last.number ? "chapter \(first.number)" : "chapters \(first.number)–\(last.number)"
    var lines = ["**Volume \(volume.ordinal): \(volume.title)** (\(span))"]
    if let goal = volume.goal, !goal.jsTrim().isEmpty { lines.append("Goal: \(capped(goal, maxTokens: goalCap))") }
    if volume.chapters.count > 1 { lines.append("Opened: \(try firstSentence(first.summary, scrub: scrub))") }
    var turns: [String] = []
    for chapter in volume.chapters.dropFirst().dropLast().suffix(lateTurns) { turns.append("ch \(chapter.number): \(try firstSentence(chapter.summary, scrub: scrub))") }
    if !turns.isEmpty { lines.append("Late turns: \(turns.joined(separator: " "))") }
    lines.append("Where it left things: \(capped(try scrub(last.summary), maxTokens: closingCap))")
    return leadingWords(lines.joined(separator: "\n"), maxTokens: volumeBlockCap)
  }

  /// The newest volumes are kept when they cannot all fit, and the text says how many earlier ones it leaves out.
  // writer-context.ts:164
  static func renderCompletedVolumes(
    _ volumes: [WriterCompletedVolume], maxTokens: Int, scrub: (String) throws(DisclosureError) -> String = { $0 }
  ) throws(DisclosureError) -> String? {
    var blocks: [String] = []
    for volume in volumes.jsStableSorted(by: { $0.ordinal < $1.ordinal }) {
      if let block = try volumeBlock(volume, scrub: scrub) { blocks.append(block) }
    }
    var kept: [String] = []
    var used = 0
    for block in blocks.reversed() {
      let tokens = countTokens(block) + 2
      if used + tokens > maxTokens { break }
      kept.insert(block, at: 0)
      used += tokens
    }
    if kept.isEmpty { return nil }
    let left = blocks.count - kept.count
    return ((left > 0 ? ["(\(left) earlier volume\(left == 1 ? "" : "s") not shown)"] : []) + kept).joined(separator: "\n\n")
  }
}
