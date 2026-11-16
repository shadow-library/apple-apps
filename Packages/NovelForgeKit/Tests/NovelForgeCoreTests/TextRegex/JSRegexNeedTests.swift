import Testing

@testable import NovelForgeCore

/// Each rule by which the matcher skips a choice, on an input where applying it in the wrong direction changes the match; expected values are bun 1.4.4's.
struct JSRegexNeedTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let source: String
    let flags: String
    let text: String
    /// `match.index`, `match[0].length` and the groups, or nil for no match.
    let expected: (index: Int, length: Int, groups: [String?])?

    var testDescription: String { "/\(source.count > 60 ? String(source.prefix(60)) + "…" : source)/\(flags) on \(describe(text))" }
  }

  static let wide = (0..<62).map { "q\($0)" } + ["abcd", "ab"] + (0..<5).map { "r\($0)" } + ["abc"]

  static let directions = [
    Case(source: "(?<=\\u{1F600}|b)a", flags: "u", text: "😀a", expected: (2, 1, [])),
    Case(source: "(?:\\u{1F600}|b)a", flags: "u", text: "😀a", expected: (0, 3, [])),
    Case(source: "(?:\\u{1F600}|b)+a", flags: "u", text: "😀😀a", expected: (0, 5, [])),
    Case(source: "(?<=(?:\\u{1F600}|b)+)a", flags: "u", text: "😀😀a", expected: (4, 1, [])),
    Case(source: "(?:\\uD83D|b)", flags: "", text: "😀", expected: (0, 1, [])),
    Case(source: "(?<=\\uDE00|b)a", flags: "", text: "😀a", expected: (2, 1, [])),
    Case(source: "(?<=\\uD83D|b)a", flags: "", text: "😀a", expected: nil),
  ]

  static let anchors = [
    Case(source: "(?<=a$|b)", flags: "", text: "a", expected: (1, 0, [])),
    Case(source: "(?:^|b)a", flags: "", text: "a", expected: (0, 1, [])),
    Case(source: "(?<=^|b)a", flags: "", text: "a", expected: (0, 1, [])),
    Case(source: "(?<=^|b)a", flags: "", text: "ca", expected: nil),
    Case(source: "a(?:$|b)", flags: "", text: "a", expected: (0, 1, [])),
    Case(source: "a(?:$|b)", flags: "", text: "ac", expected: nil),
  ]

  static let lookarounds = [
    Case(source: "a+(?=b)", flags: "", text: "aab", expected: (0, 2, [])),
    Case(source: "a+(?!b)", flags: "", text: "aab", expected: (0, 1, [])),
    Case(source: "a*(?<=a)", flags: "", text: "aa", expected: (0, 2, [])),
    Case(source: "(?<=(?=a)a*)b", flags: "", text: "ab", expected: (1, 1, [])),
    Case(source: "(?<=(?<=b)a*)c", flags: "", text: "bac", expected: (2, 1, [])),
    Case(source: "(?<=(?<!b)a*)c", flags: "", text: "bac", expected: (2, 1, [])),
  ]

  static let caseFolds = [
    Case(source: "(?:k|z)b", flags: "iu", text: "\u{212A}b", expected: (0, 2, [])),
    Case(source: "(?:k|z)b", flags: "i", text: "\u{212A}b", expected: nil),
    Case(source: "(?<=(?:k|z))b", flags: "iu", text: "\u{212A}b", expected: (1, 1, [])),
    Case(source: "(?:s|x)t", flags: "iu", text: "ſt", expected: (0, 2, [])),
    Case(source: "(?:s|x)t", flags: "i", text: "ſt", expected: nil),
    Case(source: "(?:σ|x)y", flags: "i", text: "ςy", expected: (0, 2, [])),
    Case(source: "(?:ς|x)y", flags: "iu", text: "Σy", expected: (0, 2, [])),
    Case(source: "(?:ǆ|x)y", flags: "i", text: "ǅy", expected: (0, 2, [])),
    Case(source: "(?:\\u1C88|x)y", flags: "iu", text: "\u{A64A}y", expected: (0, 2, [])),
    Case(source: "(?<=(?:\\u1C88|x))y", flags: "iu", text: "\u{A64A}y", expected: (1, 1, [])),
    Case(source: "(?:ß|x)y", flags: "iu", text: "ẞy", expected: (0, 2, [])),
  ]

  static let iterations = [
    Case(source: "(?:a|)+b", flags: "", text: "b", expected: (0, 1, [])),
    Case(source: "(?:|a)+$", flags: "", text: "aa", expected: (0, 2, [])),
    Case(source: "(?:(a)|b)*c", flags: "", text: "abc", expected: (0, 3, [nil])),
    Case(source: "(?:a?)+?b", flags: "", text: "aab", expected: (0, 3, [])),
    Case(source: "(?:(?=a)|b)+a", flags: "", text: "ba", expected: (0, 2, [])),
    Case(source: "(?:(?:ab)*c|z)", flags: "", text: "c", expected: (0, 1, [])),
    Case(source: "(?:(?:ab)+c|z)", flags: "", text: "ababc", expected: (0, 5, [])),
    Case(source: "(?:(?:a|(?=b))*b|z)", flags: "", text: "b", expected: (0, 1, [])),
  ]

  static let wideAlternations = [
    Case(source: wide.joined(separator: "|"), flags: "", text: "abc", expected: (0, 2, [])),
    Case(source: "(?<=\(wide.joined(separator: "|")))!", flags: "", text: "abc!", expected: (3, 1, [])),
  ]

  static func check(_ regexCase: Case) throws {
    let match = try JSRegex(regexCase.source, flags: regexCase.flags).exec(regexCase.text)
    guard let expected = regexCase.expected else {
      #expect(match == nil)
      return
    }
    #expect(match?.index == expected.index)
    #expect(match?.length == expected.length)
    #expect(match?.groups == expected.groups)
  }

  @Test(arguments: directions)
  func shouldReadTheSurrogateItsDirectionReachesFirst(_ regexCase: Case) throws {
    try Self.check(regexCase)
  }

  @Test(arguments: anchors)
  func shouldLetOnlyEndAnchorsForwardAndStartAnchorsBackwardRequireTheBoundary(_ regexCase: Case) throws {
    try Self.check(regexCase)
  }

  @Test(arguments: lookarounds)
  func shouldNarrowOnlyByPositiveLookaroundsReadingTheSameWay(_ regexCase: Case) throws {
    try Self.check(regexCase)
  }

  @Test(arguments: caseFolds)
  func shouldAdmitEveryUnitOfACaseFoldGroup(_ regexCase: Case) throws {
    try Self.check(regexCase)
  }

  @Test(arguments: iterations)
  func shouldKeepEmptyIterationsAndLoopsThatMayExit(_ regexCase: Case) throws {
    try Self.check(regexCase)
  }

  @Test(arguments: wideAlternations)
  func shouldTryTheAlternativesOfAWideDisjunctionInOrder(_ regexCase: Case) throws {
    try Self.check(regexCase)
  }
}
