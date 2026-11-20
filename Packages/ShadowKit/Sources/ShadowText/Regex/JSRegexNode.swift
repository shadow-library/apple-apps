enum JSRegexAnchor: Sendable {
  case start
  case end
  case wordBoundary
  case notWordBoundary
}

indirect enum JSRegexNode: Sendable {
  case character(UInt32)
  case any
  case set(JSRegexCharacterSet)
  case sequence([JSRegexNode])
  case alternation([JSRegexNode])
  case capture(JSRegexNode, index: Int)
  case lookaround(JSRegexNode, behind: Bool, negated: Bool)
  case anchor(JSRegexAnchor)
  case repetition(JSRegexNode, min: Int, max: Int, greedy: Bool, captures: Range<Int>)

  var isAnchoredAtStart: Bool {
    switch self {
    case .anchor(.start): true
    case .sequence(let terms): terms.first?.isAnchoredAtStart ?? false
    case .alternation(let alternatives): alternatives.allSatisfy(\.isAnchoredAtStart)
    case .capture(let body, _): body.isAnchoredAtStart
    default: false
    }
  }
}
