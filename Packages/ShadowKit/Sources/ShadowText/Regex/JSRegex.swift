/// A JavaScript `RegExp` built from the same source and flags, matching on UTF-16 code units (code points with `u`) exactly as ECMAScript does.
public struct JSRegex: Sendable, Hashable, CustomStringConvertible {
  private static let knownFlags: Set<Character> = ["d", "g", "i", "m", "s", "u", "v", "y"]

  public let source: String
  /// In JavaScript's canonical order, so `"ig"` reads back as `"gi"`, as `RegExp.prototype.flags` does.
  public let flags: String
  public let global: Bool
  let ignoreCase: Bool
  let unicode: Bool
  private let program: JSRegexProgram

  public init(_ source: String, flags: String = "") throws(JSRegexError) {
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

  public var description: String { "/\(source)/\(flags)" }

  /// `escapeRegExp` from the reference's `term-text.ts`.
  public static func escape(_ term: String) -> String {
    var escaped = String.UnicodeScalarView()
    for scalar in term.unicodeScalars {
      if "\\^$.*+?()[]{}|".unicodeScalars.contains(scalar) { escaped.append("\\") }
      escaped.append(scalar)
    }
    return String(escaped)
  }

  public static func == (left: JSRegex, right: JSRegex) -> Bool {
    left.source == right.source && left.flags == right.flags
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(source)
    hasher.combine(flags)
  }

  /// `re.exec(text)` from `lastIndex` 0; a call site that relies on `lastIndex` between calls uses `JSRegexCursor`.
  public func exec(_ text: String) -> JSRegexMatch? {
    let units = text.jsCodeUnits
    return firstMatchSlots(in: units, from: 0).map { JSRegexMatch(slots: $0, units: units) }
  }

  public func test(_ text: String) -> Bool {
    firstMatchSlots(in: text.jsCodeUnits, from: 0) != nil
  }

  public func machine(for units: [UInt16]) -> JSRegexMachine {
    JSRegexMachine(program, units: units)
  }

  public func firstMatchSlots(in units: [UInt16], from start: Int) -> [Int]? {
    var machine = machine(for: units)
    return machine.search(from: start)
  }

  public func allMatchSlots(in units: [UInt16]) -> [[Int]] {
    var machine = machine(for: units)
    return machine.allMatches()
  }
}
