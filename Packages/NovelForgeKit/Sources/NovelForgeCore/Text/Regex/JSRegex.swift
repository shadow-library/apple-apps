/// A JavaScript `RegExp` built from the same source and flags, matching on UTF-16 code units (code points with `u`) exactly as ECMAScript does.
struct JSRegex: Sendable, Hashable, CustomStringConvertible {
  private static let knownFlags: Set<Character> = ["d", "g", "i", "m", "s", "u", "v", "y"]

  let source: String
  /// In JavaScript's canonical order, so `"ig"` reads back as `"gi"`, as `RegExp.prototype.flags` does.
  let flags: String
  let global: Bool
  let ignoreCase: Bool
  let unicode: Bool
  private let program: JSRegexProgram

  init(_ source: String, flags: String = "") throws(JSRegexError) {
    var seen = Set<Character>()
    for flag in flags {
      guard Self.knownFlags.contains(flag), seen.insert(flag).inserted else { throw .invalidFlags(flags) }
    }
    if let refused = flags.first(where: { !"giu".contains($0) }) { throw .unsupportedFlag(refused) }
    self.source = source
    self.flags = String("giu".filter(seen.contains))
    global = seen.contains("g")
    ignoreCase = seen.contains("i")
    unicode = seen.contains("u")
    var parser = JSRegexParser(source: source, unicode: unicode)
    let root = try parser.parse()
    program = JSRegexProgram(root, captureCount: parser.captureCount, mode: JSRegexMode(unicode: unicode, ignoreCase: ignoreCase))
  }

  var description: String { "/\(source)/\(flags)" }

  /// `escapeRegExp` from the reference's `term-text.ts`.
  static func escape(_ term: String) -> String {
    var escaped = String.UnicodeScalarView()
    for scalar in term.unicodeScalars {
      if "\\^$.*+?()[]{}|".unicodeScalars.contains(scalar) { escaped.append("\\") }
      escaped.append(scalar)
    }
    return String(escaped)
  }

  static func == (left: JSRegex, right: JSRegex) -> Bool {
    left.source == right.source && left.flags == right.flags
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(source)
    hasher.combine(flags)
  }

  /// `re.exec(text)` from `lastIndex` 0; a call site that relies on `lastIndex` between calls uses `JSRegexCursor`.
  func exec(_ text: String) -> JSRegexMatch? {
    let units = text.jsCodeUnits
    return firstMatchSlots(in: units, from: 0).map { JSRegexMatch(slots: $0, units: units) }
  }

  func test(_ text: String) -> Bool {
    firstMatchSlots(in: text.jsCodeUnits, from: 0) != nil
  }

  func machine(for units: [UInt16]) -> JSRegexMachine {
    JSRegexMachine(program, units: units)
  }

  func firstMatchSlots(in units: [UInt16], from start: Int) -> [Int]? {
    var machine = machine(for: units)
    return machine.search(from: start)
  }

  /// Every match from offset 0, an empty match stepping one code unit (one code point with `u`), as `matchAll` and a global `match` or `replace` do.
  func allMatchSlots(in units: [UInt16]) -> [[Int]] {
    var machine = machine(for: units)
    var matches: [[Int]] = []
    var lastIndex = 0
    while let slots = machine.search(from: lastIndex) {
      matches.append(slots)
      lastIndex = slots[1] == slots[0] ? machine.advance(slots[1]) : slots[1]
    }
    return matches
  }
}
