import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowText

struct JSRegexBehaviourTests {
  private static let sharedPattern = try? JSRegex(#"(?<![\p{L}\p{N}_])the heir(?![\p{L}\p{N}_])"#, flags: "giu")

  @Test(arguments: ["m", "s", "y", "d", "v", "gm", "uy"])
  func shouldRefuseAFlagItDoesNotSupport(flags: String) {
    #expect(throws: JSRegexError.self) { try JSRegex("a", flags: flags) }
    guard let first = flags.first(where: { !"giu".contains($0) }) else { return }
    #expect(throws: JSRegexError.unsupportedFlag(first)) { try JSRegex("a", flags: flags) }
  }

  @Test(arguments: ["x", "gg", "iui", "G"])
  func shouldRefuseFlagsJavaScriptRejects(flags: String) throws {
    #expect(throws: JSRegexError.invalidFlags(flags)) { try JSRegex("a", flags: flags) }
    #expect(try JSOracle().call("(flags) => { try { new RegExp('a', flags); return false; } catch { return true; } }", .string(flags)) == .boolean(true))
  }

  @Test(arguments: [
    ("(a)\\1", ""), ("(?<name>a)", ""), ("\\k<name>", ""), ("\\p{L}", ""), ("\\p{Greek}", "u"), ("\\p{Script=Latin}", "u"), ("\\cJ", ""), ("\\01", ""),
    ("(?i:a)", ""), ("(?=a)*", ""), ("[\\d-z]", ""), ("\\a", ""), ("\\x4", ""), ("\\u12", ""), ("[\\B]", ""),
  ])
  func shouldRefuseAConstructOutsideTheSupportedSubset(source: String, flags: String) {
    #expect {
      try JSRegex(source, flags: flags)
    } throws: { error in
      guard case .unsupported = error as? JSRegexError else { return false }
      return true
    }
  }

  @Test(arguments: [
    ("a)", ""), ("(a", ""), ("[a", ""), ("a**", ""), ("*a", ""), ("[b-a]", ""), ("a{2,1}", ""), ("\\", ""), ("{", "u"), ("]", "u"), ("\\-", "u"), ("(?<=a)+", ""),
    ("\\u{110000}", "u"), ("\\q", "u"), ("(?<=a){2}", "u"), ("x{1}{2}", ""),
  ])
  func shouldRejectSyntaxJavaScriptRejects(source: String, flags: String) throws {
    #expect {
      try JSRegex(source, flags: flags)
    } throws: { error in
      guard case .syntax = error as? JSRegexError else { return false }
      return true
    }
    let rejected = try JSOracle().call("(source, flags) => { try { new RegExp(source, flags); return false; } catch { return true; } }", .string(source), .string(flags))
    #expect(rejected == .boolean(true), "JavaScript accepts /\(source)/\(flags)")
  }

  @Test func shouldCountSAndKLookalikesAsWordCharactersOnlyUnderUnicodeIgnoreCase() throws {
    #expect(JSCaseFolding.unicodeExtraWordCharacters == [0x017F, 0x212A])
    #expect(try JSRegex("\\bſ", flags: "iu").test("ſ"))
    #expect(try !JSRegex("\\bſ", flags: "u").test("ſ"))
    #expect(try !JSRegex("\\bſ", flags: "i").test("ſ"))
  }

  @Test func shouldBeSendableAndGiveTheSameAnswersFromTwoTasks() async throws {
    let pattern = try #require(Self.sharedPattern)
    let text = String(repeating: "The Heir met the heir; theheir and the heirs. ", count: 200)
    async let first = Task.detached { text.jsMatchAll(pattern).map(\.index) }.value
    async let second = Task.detached { text.jsReplace(pattern) { _ in "[withheld]" } }.value
    let (indices, scrubbed) = await (first, second)
    #expect(indices.count == 400)
    #expect(scrubbed == String(repeating: "[withheld] met [withheld]; theheir and the heirs. ", count: 200))
  }

  @Test func shouldEscapeExactlyAsTheReferenceEscapeRegExp() throws {
    let oracle = try JSOracle()
    try forAll(iterations: 200) { generator in
      let text = generator.jsText(maxPieces: 10) + generator.pick(from: ["", ".", "*+?^$", "{}()|[]\\", "/-", "a.b*c"])
      try expectExactlySame(JSRegex.escape(text), try oracle.call("(term) => term.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&')", .string(text)), describe(text))
      for flags in ["", "u", "iu"] {
        let match = try JSRegex(JSRegex.escape(text), flags: flags).exec(text)
        #expect(match?.index == 0 && match?.length == text.jsLength, "\(describe(text)) /\(flags)")
      }
    }
  }

  /// A `lastIndex` inside a surrogate pair under `u` is pinned to bun and V8, since the system JavaScriptCore starts after the pair.
  @Test func shouldReproduceTheLastIndexSequenceOfAGlobalExpression() throws {
    let plans: [(String, String, String, [Int])] = [
      ("\\r\\n|\\r|\\n", "g", "one\r\ntwo\rthree\n\nfour", Array(repeating: -1, count: 7)),
      ("like an?", "gi", "Like a cat, like an owl, LIKE A dog", Array(repeating: -1, count: 5)),
      (".", "gu", "😀x😀", [2, -1, -1, -1, 5, -1]),
      ("x", "g", "axbx", [-1, 9, -1, 3, -1, -1]),
      ("x", "", "axbx", [3, -1, 1, -1]),
      ("(?:)", "g", "ab", Array(repeating: -1, count: 4)),
    ]
    let oracle = try JSOracle()
    let replay = """
      (source, flags, text, plan) => {
        const re = new RegExp(source, flags);
        return plan.map(start => {
          if (start !== '-1') re.lastIndex = Number(start);
          const match = re.exec(text);
          return [match ? match.index : -1, re.lastIndex];
        });
      }
      """
    for (source, flags, text, plan) in plans {
      var cursor = JSRegexCursor(try JSRegex(source, flags: flags))
      let swift = plan.map { start -> [Int] in
        if start != -1 { cursor.lastIndex = start }
        let match = cursor.exec(text)
        return [match?.index ?? -1, cursor.lastIndex]
      }
      try expectExactlySame(swift, try oracle.call(replay, .string(source), .string(flags), .string(text), .strings(plan.map(String.init))), "/\(source)/\(flags)")
    }
    var astral = JSRegexCursor(try JSRegex(".", flags: "gu"))
    astral.lastIndex = 1
    let fromInsidePair = astral.exec("😀x")
    #expect(fromInsidePair?.index == 0 && fromInsidePair?.length == 2 && astral.lastIndex == 2)
    var lines = JSRegexCursor(try JSRegex("\\r\\n|\\r|\\n", flags: "g"))
    #expect(lines.test("a\nb") && lines.lastIndex == 2 && !lines.test("a\nb") && lines.lastIndex == 0)
  }

  @Test func shouldMatchLoneSurrogatesOnCodeUnitsAsJavaScriptDoes() throws {
    let patterns = [
      ("[\\uD800-\\uDBFF](?![\\uDC00-\\uDFFF])|(?<![\\uD800-\\uDBFF])[\\uDC00-\\uDFFF]", ""), (".", ""), ("[^a]", ""), ("\\S", ""), (".", "u"), ("[^a]", "u"),
      ("\\uD83D", "u"), ("\\uDE00", ""), ("(?<=\\uD83D)\\uDE00", ""), ("(?<=.)a", "u"),
    ]
    let oracle = try JSOracle()
    var generator = SeededGenerator(seed: 0x10E5)
    let alphabet: [[UInt16]] = [[0x61], [0x20], [0xD83D], [0xDE00], [0xD83D, 0xDE00], [0xDBFF], [0xDC00], [0xD835, 0xDC9C]]
    let inputs = (0..<200).map { _ in (0..<generator.int(in: 0...8)).flatMap { _ in generator.pick(from: alphabet) } }
    let evaluate = """
      (source, flags, inputs) => inputs.map(text => {
        const all = new RegExp(source, flags + 'g');
        return [[...text.matchAll(all)].map(m => [m.index, m.index + m[0].length]), new RegExp(source, flags).test(text)];
      })
      """
    var loneMatches = 0
    for (source, flags) in patterns {
      let regex = try JSRegex(source, flags: flags)
      let swift = inputs.map { units -> JSOracleValue in
        let all = regex.allMatchSlots(in: units).map { [$0[0], $0[1]] }
        return .array([all.oracleValue, (regex.firstMatchSlots(in: units, from: 0) != nil).oracleValue])
      }
      try expectExactlySame(swift, try oracle.call(evaluate, .string(source), .string(flags), .codeUnitLists(inputs)), "/\(source)/\(flags)")
      if source.hasPrefix("[\\uD800") { loneMatches = inputs.filter { regex.firstMatchSlots(in: $0, from: 0) != nil }.count }
    }
    #expect(loneMatches > 50)
    #expect(try !JSRegex("[\\uD800-\\uDBFF](?![\\uDC00-\\uDFFF])|(?<![\\uD800-\\uDBFF])[\\uDC00-\\uDFFF]").test("😀\u{1F468}\u{200D}"))
  }

  /// Short inputs only: the differential's long repeated runs make `x+$` patterns quadratic in JavaScript too.
  @Test func shouldMatchEveryReferenceRegexOverTwoHundredThousandUnitsWithinAGenerousBound() async throws {
    let bound = Duration.seconds(15)
    let timings = try await withThrowingTaskGroup(of: (String, Duration).self) { group in
      var seen = Set<Int>()
      for regexCase in try RegexCatalog.cases() where seen.insert(regexCase.entry).inserted {
        let inputs = try JSRegexDifferentialTests.inputs(for: regexCase).filter { $0.jsLength <= 60 }
        group.addTask {
          var units: [UInt16] = []
          var index = 0
          while units.count < 200_000 {
            units += inputs[index % inputs.count].utf16
            units.append(0x20)
            index += 1
          }
          let regex = try JSRegex(regexCase.source, flags: regexCase.flags)
          let start = ContinuousClock.now
          _ = regex.allMatchSlots(in: units)
          return (regexCase.description, ContinuousClock.now - start)
        }
      }
      var timings: [(String, Duration)] = []
      for try await timing in group { timings.append(timing) }
      return timings
    }
    #expect(timings.count == 127)
    let slow = timings.filter { $0.1 > bound }
    #expect(slow.isEmpty, "\(slow.map { "\($0.0): \($0.1)" })")
  }
}
