import ShadowText

// apps/novel-forge-server/src/modules/ai/retrieval/chunker.ts
enum RetrievalChunker {
  // chunker.ts:6
  static let defaultTargetChars = 2000

  private static let paragraphBreak = ProseRegex.literal(#"\n\n+"#)
  private static let sentenceEnd = ProseRegex.literal(#"[.!?] "#, "g")
  private static let paragraphJoin = "\n\n".jsCodeUnits

  /// Works on UTF-16 code units, as the reference measures and cuts; a cut through a surrogate pair drops the dangling halves where JavaScript keeps them.
  // chunker.ts:22
  static func chunk(_ text: String, targetChars: Int = defaultTargetChars) -> [String] {
    precondition(targetChars > 0, "the reference never ends with a target of \(targetChars)")
    var chunks: [[UInt16]] = []
    var current: [UInt16] = []
    for paragraph in text.jsSplit(paragraphBreak).map(\.jsCodeUnits) {
      if paragraph.count > targetChars * 2 {
        if !current.isEmpty {
          chunks.append(current)
          current = []
        }
        var remaining = paragraph
        while remaining.count > targetChars * 2 {
          let (head, tail) = splitAtSentence(remaining, limit: targetChars)
          chunks.append(head)
          remaining = tail
        }
        if !remaining.isEmpty { current = remaining }
        continue
      }
      let candidate = current.isEmpty ? paragraph : current + paragraphJoin + paragraph
      if candidate.count > targetChars, !current.isEmpty {
        chunks.append(current)
        current = paragraph
      } else {
        current = candidate
      }
    }
    if !current.isEmpty { chunks.append(current) }
    if chunks.isEmpty { chunks.append([]) }
    return chunks.map { JSText.string(fromCodeUnits: $0) }
  }

  // chunker.ts:8
  private static func splitAtSentence(_ units: [UInt16], limit: Int) -> ([UInt16], [UInt16]) {
    var machine = sentenceEnd.machine(for: units)
    var lastGood = 0
    var position = 0
    while let slots = machine.search(from: position) {
      if slots[0] + 1 >= limit { break }
      lastGood = slots[0] + 1
      position = slots[1]
    }
    guard lastGood > 0 else { return (Array(units[..<limit]), Array(units[limit...])) }
    return (Array(units[..<lastGood]), trimmingLeadingWhitespace(units[lastGood...]))
  }

  private static func trimmingLeadingWhitespace(_ units: ArraySlice<UInt16>) -> [UInt16] {
    Array(units.drop { unit in Unicode.Scalar(unit).map(JSText.isWhitespace) ?? false })
  }
}
