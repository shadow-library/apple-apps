import ShadowTestSupport
import Testing

@testable import NovelForgeCore

/// Constructs the reference does not use but the engine accepts, compared with JavaScript on short inputs over a case-folding alphabet.
struct JSRegexConstructTests {
  private static let alphabet = [
    "a", "b", "c", "d", "x", "_", "1", "2", " ", "\n", "ſ", "K", "k", "S", "s", "ς", "σ", "Σ", "ß", "ẞ", "İ", "i", "I", "ı", "😀", "𝒜", "é", "ﬀ", "f", "\u{345}",
    "ι", "-", ".",
  ]

  private static let patterns: [(String, String)] = [
    ("(a)|b", "g"), ("(a)?b", "g"), ("(?:(a)|b)+", "g"), ("(a*)*", "g"), ("(a*)+b", ""), ("(?:a|)*?b", "g"), ("a{2,3}?", "g"), ("a{2,}", "g"),
    ("(?<=(\\w+))x", "g"), ("(?<=(a)(b))c", "g"), ("(?<!a)b", "g"), ("\\Bb\\B", "g"), ("\\W+", "g"), ("\\D+", "gu"), ("\\S+", "g"), ("[^\\s\\d]+", "g"),
    ("\\P{L}+", "gu"), ("[\\P{L}a]", "gu"), ("..", "g"), (".", "gu"), ("[^a]", "g"), ("\\u{1F600}", "gu"), ("\\uD83D\\uDE00", "gu"), ("\\uD83D", "g"),
    ("\\x41", "gi"), ("[\\x41-\\x5A]+", "gi"), ("(?=(a))a", "g"), ("(?!(a))\\w", "g"), ("(?:)", "g"), ("(?:)", "gu"), ("^$", ""), ("x*", "gu"),
    ("(\\d)(\\d)?", "g"), ("[-a]", "g"), ("[a-]", "g"), ("\\s", "gu"), ("[\\b]", "g"), ("\\0", "g"), ("a|ab|abc", "g"), ("(a|ab)(c|bcd)(d*)", ""),
    ("\\w+", "giu"), ("[A-Z]", "gi"), ("ς", "gi"), ("Σ", "giu"), ("ß", "giu"), ("[İ]", "giu"), ("ﬀ", "giu"), ("\\bk", "giu"),
    ("[^ſ]", "gi"), ("[^ſ]", "giu"), ("(?<=\\d+)\\.", "g"), ("(?<![a-z]{2,})s", "gi"), ("((a)|(b))+", "g"), ("(?:a(?=b)|.)+?c", "g"), ("\\W", "giu"),
  ]

  @Test(arguments: patterns)
  func shouldMatchJavaScriptOnAConstructOutsideTheReference(source: String, flags: String) throws {
    let regex = try JSRegex(source, flags: flags)
    var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: (source + flags).utf8.reduce(17) { $0 &* 31 &+ Int($1) }))
    let inputs = (0..<200).map { _ in (0..<generator.int(in: 0...10)).map { _ in generator.pick(from: Self.alphabet) }.joined() }
    let template = "[$&|$1|$2|$`|$'|$$|$3$9|$01|$10]"
    let expected = try JSOracle().call(
      JSRegexDifferentialTests.evaluate, .string(source), .string(flags), .strings(inputs), .string(template), .string(JSRegexDifferentialTests.genericTemplate))
    guard case .array(let perInput) = expected else { throw Mismatch(description: "unexpected oracle output") }
    for (text, javaScript) in zip(inputs, perInput) {
      guard case .array(let results) = javaScript else { throw Mismatch(description: "unexpected oracle output") }
      let swift = JSRegexDifferentialTests.swiftResults(regex, text, siteTemplate: template)
      let replaceSkipsInsidePair = Self.hasEmptyMatchInsideSurrogatePair(results.first, text)
      for (operation, (mine, theirs)) in zip(JSRegexDifferentialTests.operations, zip(swift, results)) where !(replaceSkipsInsidePair && operation.hasPrefix("replace")) {
        #expect(mine == theirs.droppingLoneSurrogates, "/\(source)/\(flags) \(operation) on \(describe(text)): Swift \(mine) but JavaScript \(theirs)")
      }
    }
  }

  /// As bun and V8: the system JavaScriptCore's global `replace` skips the empty match between surrogate halves.
  @Test func shouldReplaceAnEmptyMatchBetweenSurrogateHalvesWithoutTheUnicodeFlag() throws {
    #expect("_😀".jsReplace(try JSRegex("(?:)", flags: "g"), "-") == "-_---")
    #expect("_😀".jsReplace(try JSRegex("(?:)", flags: "gu"), "-") == "-_-😀-")
    #expect("_😀".jsReplace(try JSRegex("(?:)", flags: "g")) { "<\($0.index)>" } == "<0>_<1><2><3>")
  }

  /// As bun and V8: the system JavaScriptCore does not fold a class range under `iu`.
  @Test func shouldFoldAClassRangeUnderUnicodeIgnoreCase() throws {
    #expect("aſ".jsMatchAll(try JSRegex("[a-z]+", flags: "giu")).map(\.text) == ["aſ"])
    #expect("\u{212A}elvin".jsMatchAll(try JSRegex("[a-z]+", flags: "giu")).map(\.text) == ["\u{212A}elvin"])
    #expect(try JSRegex("(?<=[a-z])x", flags: "iu").exec("ſx")?.index == 1)
    #expect(try !JSRegex("[a-z]", flags: "i").test("ſ"))
  }

  private static func hasEmptyMatchInsideSurrogatePair(_ matches: JSOracleValue?, _ text: String) -> Bool {
    guard case .array(let all)? = matches else { return false }
    let units = text.jsCodeUnits
    return all.contains { match in
      guard case .array(let parts) = match, case .number(let index)? = parts.first, case .string(let matched)? = parts.dropFirst().first, matched.isEmpty else { return false }
      let at = Int(index)
      return at > 0 && at < units.count && JSRegexMachine.isHigh(units[at - 1]) && JSRegexMachine.isLow(units[at])
    }
  }
}
