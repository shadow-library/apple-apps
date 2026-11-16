/// The code units a match can start with, when every match must consume one: a search skips any other start without running the matcher.
struct JSRegexFirstUnits: Sendable {
  private enum Start {
    case zeroWidth
    case units(Set<UInt16>)
  }

  private static let enumerableLimit = 512
  private static let whitespace: [UInt32] = (0...0xFFFF).filter(JSRegexMode.isWhitespace)

  private let words: [UInt64]

  init?(_ root: JSRegexNode, mode: JSRegexMode) {
    guard case .units(let units) = Self.start(of: root, mode: mode) else { return nil }
    var words = Array(repeating: UInt64(0), count: 1024)
    for unit in units { words[Int(unit >> 6)] |= 1 << UInt64(unit & 63) }
    self.words = words
  }

  func contains(_ unit: UInt16) -> Bool {
    words[Int(unit >> 6)] >> UInt64(unit & 63) & 1 == 1
  }

  func next(in units: [UInt16], from start: Int, unicode: Bool) -> Int {
    var index = start
    while index < units.count {
      let unit = units[index]
      if words[Int(unit >> 6)] >> UInt64(unit & 63) & 1 == 1 { return index }
      index += unicode && unit & 0xFC00 == 0xD800 && index + 1 < units.count && units[index + 1] & 0xFC00 == 0xDC00 ? 2 : 1
    }
    return index
  }

  private static func start(of node: JSRegexNode, mode: JSRegexMode) -> Start? {
    switch node {
    case .character(let value):
      return .units(units(of: [value], mode: mode))
    case .any:
      return nil
    case .set(let set):
      return members(of: set, mode: mode).map { .units(units(of: $0, mode: mode)) }
    case .sequence(let terms):
      for term in terms {
        guard let start = start(of: term, mode: mode) else { return nil }
        if case .units = start { return start }
      }
      return .zeroWidth
    case .alternation(let alternatives):
      var union = Set<UInt16>()
      for alternative in alternatives {
        guard case .units(let units) = start(of: alternative, mode: mode) else { return nil }
        union.formUnion(units)
      }
      return .units(union)
    case .capture(let body, _):
      return start(of: body, mode: mode)
    case .lookaround, .anchor:
      return .zeroWidth
    case .repetition(let body, let min, _, _, _):
      return min > 0 ? start(of: body, mode: mode) : nil
    }
  }

  private static func members(of set: JSRegexCharacterSet, mode: JSRegexMode) -> [UInt32]? {
    guard !set.negated else { return nil }
    var members: [UInt32] = []
    for item in set.items {
      switch item {
      case .range(let lower, let upper):
        guard upper - lower < enumerableLimit else { return nil }
        members.append(contentsOf: lower...upper)
      case .digit(negated: false): members.append(contentsOf: 0x30...0x39)
      case .space(negated: false): members.append(contentsOf: whitespace)
      case .word(negated: false):
        members.append(contentsOf: JSRegexMode.asciiWordCharacters + (mode.unicode && mode.ignoreCase ? Array(JSCaseFolding.unicodeExtraWordCharacters) : []))
      default: return nil
      }
      if members.count > enumerableLimit { return nil }
    }
    return members
  }

  private static func units(of values: [UInt32], mode: JSRegexMode) -> Set<UInt16> {
    let all = mode.ignoreCase ? values.flatMap { JSCaseFolding.equivalents($0, unicode: mode.unicode) } : values
    return Set(all.map { $0 > 0xFFFF ? UInt16(0xD800 + (($0 - 0x1_0000) >> 10)) : UInt16(truncatingIfNeeded: $0) })
  }
}
