/// The ECMAScript pattern grammar with Annex B for patterns without `u`; backreferences, named groups, `\c`, legacy octal and letter identity escapes are refused.
struct JSRegexParser {
  private enum Quantifiability {
    case quantifiable
    case assertion
    case lookahead
  }

  private enum ClassAtom {
    case character(UInt32)
    case items([JSRegexClassItem])

    var items: [JSRegexClassItem] {
      switch self {
      case .character(let value): [.range(value, value)]
      case .items(let items): items
      }
    }
  }

  private static let syntaxCharacters: Set<UInt32> = Set("^$\\.*+?()[]{}|/".unicodeScalars.map(\.value))

  private let pattern: [UInt32]
  private let unicode: Bool
  private var position = 0
  private(set) var captureCount = 0

  init(source: String, unicode: Bool) {
    pattern = unicode ? source.unicodeScalars.map(\.value) : source.utf16.map(UInt32.init)
    self.unicode = unicode
  }

  mutating func parse() throws(JSRegexError) -> JSRegexNode {
    let node = try disjunction()
    if position < pattern.count { throw syntax("unmatched \")\"") }
    return node
  }

  private var current: UInt32? { position < pattern.count ? pattern[position] : nil }

  private func peek(_ offset: Int) -> UInt32? {
    position + offset < pattern.count ? pattern[position + offset] : nil
  }

  private func syntax(_ reason: String) -> JSRegexError {
    .syntax(reason, offset: position)
  }

  private func unsupported(_ construct: String) -> JSRegexError {
    .unsupported(construct, offset: position)
  }

  private func isAt(_ character: Unicode.Scalar) -> Bool {
    current == character.value
  }

  private mutating func disjunction() throws(JSRegexError) -> JSRegexNode {
    var alternatives = [try alternative()]
    while isAt("|") {
      position += 1
      alternatives.append(try alternative())
    }
    return alternatives.count == 1 ? alternatives[0] : .alternation(alternatives)
  }

  private mutating func alternative() throws(JSRegexError) -> JSRegexNode {
    var terms: [JSRegexNode] = []
    while let character = current, character != UInt32(ascii: "|"), character != UInt32(ascii: ")") { terms.append(try term()) }
    return terms.count == 1 ? terms[0] : .sequence(terms)
  }

  private mutating func term() throws(JSRegexError) -> JSRegexNode {
    let capturesBefore = captureCount
    let (atom, quantifiability) = try atomOrAssertion()
    let start = position
    guard let (min, max) = try quantifier() else { return atom }
    switch quantifiability {
    case .quantifiable: break
    case .assertion: throw JSRegexError.syntax("nothing to repeat", offset: start)
    case .lookahead: throw unicode ? JSRegexError.syntax("a lookahead cannot be repeated", offset: start) : JSRegexError.unsupported("a repeated lookahead", offset: start)
    }
    var greedy = true
    if isAt("?") {
      position += 1
      greedy = false
    }
    return .repetition(atom, min: min, max: max, greedy: greedy, captures: (capturesBefore + 1)..<(captureCount + 1))
  }

  private mutating func quantifier() throws(JSRegexError) -> (Int, Int)? {
    guard let character = current else { return nil }
    switch character {
    case UInt32(ascii: "*"):
      position += 1
      return (0, Int.max)
    case UInt32(ascii: "+"):
      position += 1
      return (1, Int.max)
    case UInt32(ascii: "?"):
      position += 1
      return (0, 1)
    case UInt32(ascii: "{"):
      guard let (bounds, length) = bracedQuantifier(at: position) else { return nil }
      if bounds.0 > bounds.1 { throw syntax("numbers out of order in a quantifier") }
      position += length
      return bounds
    default:
      return nil
    }
  }

  private func bracedQuantifier(at start: Int) -> ((Int, Int), Int)? {
    var index = start + 1
    func digits() -> Int? {
      var value: Int?
      while index < pattern.count, let digit = Self.decimalDigit(pattern[index]) {
        let base = value ?? 0
        value = base > 1_000_000_000_000 ? base : base * 10 + digit
        index += 1
      }
      return value
    }
    guard let min = digits() else { return nil }
    var max = min
    if index < pattern.count, pattern[index] == UInt32(ascii: ",") {
      index += 1
      max = digits() ?? Int.max
    }
    guard index < pattern.count, pattern[index] == UInt32(ascii: "}") else { return nil }
    return ((min, max), index + 1 - start)
  }

  private mutating func atomOrAssertion() throws(JSRegexError) -> (JSRegexNode, Quantifiability) {
    guard let character = current else { throw syntax("unexpected end of pattern") }
    switch character {
    case UInt32(ascii: "^"):
      position += 1
      return (.anchor(.start), .assertion)
    case UInt32(ascii: "$"):
      position += 1
      return (.anchor(.end), .assertion)
    case UInt32(ascii: "."):
      position += 1
      return (.any, .quantifiable)
    case UInt32(ascii: "("):
      return try group()
    case UInt32(ascii: "["):
      return (.set(try characterClass()), .quantifiable)
    case UInt32(ascii: "\\"):
      if peek(1) == UInt32(ascii: "b") || peek(1) == UInt32(ascii: "B") {
        let negated = peek(1) == UInt32(ascii: "B")
        position += 2
        return (.anchor(negated ? .notWordBoundary : .wordBoundary), .assertion)
      }
      position += 1
      return (try atomEscape(), .quantifiable)
    case UInt32(ascii: "*"), UInt32(ascii: "+"), UInt32(ascii: "?"):
      throw syntax("nothing to repeat")
    case UInt32(ascii: "{"):
      if unicode || bracedQuantifier(at: position) != nil { throw syntax("nothing to repeat") }
      position += 1
      return (.character(character), .quantifiable)
    case UInt32(ascii: "}"), UInt32(ascii: "]"):
      if unicode { throw syntax("lone quantifier bracket") }
      position += 1
      return (.character(character), .quantifiable)
    default:
      position += 1
      return (.character(character), .quantifiable)
    }
  }

  private mutating func group() throws(JSRegexError) -> (JSRegexNode, Quantifiability) {
    position += 1
    guard isAt("?") else {
      captureCount += 1
      let index = captureCount
      let body = try disjunction()
      try closeGroup()
      return (.capture(body, index: index), .quantifiable)
    }
    switch (peek(1), peek(2)) {
    case (UInt32(ascii: ":"), _):
      position += 2
      let body = try disjunction()
      try closeGroup()
      return (body, .quantifiable)
    case (UInt32(ascii: "="), _), (UInt32(ascii: "!"), _):
      let negated = peek(1) == UInt32(ascii: "!")
      position += 2
      let body = try disjunction()
      try closeGroup()
      return (.lookaround(body, behind: false, negated: negated), .lookahead)
    case (UInt32(ascii: "<"), UInt32(ascii: "=")), (UInt32(ascii: "<"), UInt32(ascii: "!")):
      let negated = peek(2) == UInt32(ascii: "!")
      position += 3
      let body = try disjunction()
      try closeGroup()
      return (.lookaround(body, behind: true, negated: negated), .assertion)
    case (UInt32(ascii: "<"), _):
      throw unsupported("a named group")
    default:
      throw unsupported("a group modifier")
    }
  }

  private mutating func closeGroup() throws(JSRegexError) {
    guard isAt(")") else { throw syntax("unterminated group") }
    position += 1
  }

  private mutating func atomEscape() throws(JSRegexError) -> JSRegexNode {
    if let items = try classEscapeItems() { return .set(JSRegexCharacterSet(items: items, negated: false)) }
    return .character(try characterEscape(inClass: false))
  }

  private mutating func classEscapeItems() throws(JSRegexError) -> [JSRegexClassItem]? {
    guard let character = current else { throw syntax("\\ at end of pattern") }
    let item: JSRegexClassItem
    switch character {
    case UInt32(ascii: "d"): item = .digit(negated: false)
    case UInt32(ascii: "D"): item = .digit(negated: true)
    case UInt32(ascii: "s"): item = .space(negated: false)
    case UInt32(ascii: "S"): item = .space(negated: true)
    case UInt32(ascii: "w"): item = .word(negated: false)
    case UInt32(ascii: "W"): item = .word(negated: true)
    case UInt32(ascii: "p"), UInt32(ascii: "P"):
      guard unicode else { throw unsupported("\\p without the u flag") }
      return [try propertyEscape(negated: character == UInt32(ascii: "P"))]
    default: return nil
    }
    position += 1
    return [item]
  }

  private mutating func propertyEscape(negated: Bool) throws(JSRegexError) -> JSRegexClassItem {
    position += 1
    guard isAt("{") else { throw syntax("invalid property name") }
    position += 1
    var name = String.UnicodeScalarView()
    while let character = current, character != UInt32(ascii: "}") {
      guard let scalar = Unicode.Scalar(character) else { throw syntax("invalid property name") }
      name.append(scalar)
      position += 1
    }
    guard isAt("}") else { throw syntax("invalid property name") }
    guard let property = JSRegexProperty(expression: String(name)) else { throw unsupported("the property \\p{\(String(name))}") }
    position += 1
    return .property(property, negated: negated)
  }

  private mutating func characterEscape(inClass: Bool) throws(JSRegexError) -> UInt32 {
    guard let character = current else { throw syntax("\\ at end of pattern") }
    position += 1
    switch character {
    case UInt32(ascii: "f"): return 0x0C
    case UInt32(ascii: "n"): return 0x0A
    case UInt32(ascii: "r"): return 0x0D
    case UInt32(ascii: "t"): return 0x09
    case UInt32(ascii: "v"): return 0x0B
    case UInt32(ascii: "b") where inClass: return 0x08
    case UInt32(ascii: "-") where inClass && unicode: return character
    case UInt32(ascii: "0"):
      if let next = current, Self.decimalDigit(next) != nil { throw unsupported("a legacy octal escape") }
      return 0
    case UInt32(ascii: "1")...UInt32(ascii: "9"): throw unsupported("a backreference")
    case UInt32(ascii: "x"):
      guard let value = hexDigits(count: 2) else { throw unicode ? syntax("invalid \\x escape") : unsupported("an incomplete \\x escape") }
      return value
    case UInt32(ascii: "u"): return try unicodeEscape()
    case UInt32(ascii: "c"): throw unsupported("a control escape")
    case UInt32(ascii: "k"): throw unsupported("a named backreference")
    default:
      if unicode {
        guard Self.syntaxCharacters.contains(character) else { throw syntax("invalid escape") }
        return character
      }
      if Self.isASCIIAlphanumeric(character) { throw unsupported("an identity escape of a letter or digit") }
      return character
    }
  }

  private mutating func unicodeEscape() throws(JSRegexError) -> UInt32 {
    if unicode, isAt("{") {
      let start = position
      position += 1
      var value: UInt32 = 0
      var count = 0
      while let character = current, let digit = Self.hexDigit(character) {
        value = value > 0x10_FFFF ? value : value * 16 + digit
        count += 1
        position += 1
      }
      guard count > 0, isAt("}"), value <= 0x10_FFFF else {
        position = start
        throw syntax("invalid \\u{} escape")
      }
      position += 1
      return value
    }
    guard let value = hexDigits(count: 4) else { throw unicode ? syntax("invalid \\u escape") : unsupported("an incomplete \\u escape") }
    if unicode, (0xD800...0xDBFF).contains(value), peek(0) == UInt32(ascii: "\\"), peek(1) == UInt32(ascii: "u") {
      let saved = position
      position += 2
      if let low = hexDigits(count: 4), (0xDC00...0xDFFF).contains(low) { return 0x1_0000 + ((value - 0xD800) << 10) + (low - 0xDC00) }
      position = saved
    }
    return value
  }

  private mutating func hexDigits(count: Int) -> UInt32? {
    guard position + count <= pattern.count else { return nil }
    var value: UInt32 = 0
    for offset in 0..<count {
      guard let digit = Self.hexDigit(pattern[position + offset]) else { return nil }
      value = value * 16 + digit
    }
    position += count
    return value
  }

  private mutating func characterClass() throws(JSRegexError) -> JSRegexCharacterSet {
    position += 1
    var negated = false
    if isAt("^") {
      negated = true
      position += 1
    }
    var items: [JSRegexClassItem] = []
    while true {
      guard let character = current else { throw syntax("unterminated character class") }
      if character == UInt32(ascii: "]") { break }
      let first = try classAtom()
      guard isAt("-"), let next = peek(1), next != UInt32(ascii: "]") else {
        items.append(contentsOf: first.items)
        continue
      }
      position += 1
      let second = try classAtom()
      guard case .character(let lower) = first, case .character(let upper) = second else {
        throw unicode ? syntax("a class escape cannot bound a range") : unsupported("a range bounded by a class escape")
      }
      if lower > upper { throw syntax("range out of order in character class") }
      items.append(.range(lower, upper))
    }
    position += 1
    return JSRegexCharacterSet(items: items, negated: negated)
  }

  private mutating func classAtom() throws(JSRegexError) -> ClassAtom {
    guard let character = current else { throw syntax("unterminated character class") }
    guard character == UInt32(ascii: "\\") else {
      position += 1
      return .character(character)
    }
    position += 1
    if isAt("B") { throw unicode ? syntax("invalid class escape") : unsupported("\\B in a character class") }
    if let items = try classEscapeItems() { return .items(items) }
    return .character(try characterEscape(inClass: true))
  }

  private static func decimalDigit(_ value: UInt32) -> Int? {
    (0x30...0x39).contains(value) ? Int(value - 0x30) : nil
  }

  private static func hexDigit(_ value: UInt32) -> UInt32? {
    switch value {
    case 0x30...0x39: value - 0x30
    case 0x41...0x46: value - 0x41 + 10
    case 0x61...0x66: value - 0x61 + 10
    default: nil
    }
  }

  private static func isASCIIAlphanumeric(_ value: UInt32) -> Bool {
    (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
  }
}

extension UInt32 {
  fileprivate init(ascii scalar: Unicode.Scalar) {
    self = scalar.value
  }
}
