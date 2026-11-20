import ShadowTestSupport
import Testing

@testable import ShadowText

/// bun's results for every reference entry, recorded by `Fixtures/regex/generate.ts`; compared exactly, with no tolerance.
struct JSRegexBunFixtureTests {
  struct Fixture: Decodable {
    let unicode: UnicodeData
    let cases: [Case]
  }

  struct UnicodeData: Decodable {
    let runtime: String
    let properties: [String: [Int]]
    let foldPairs: String
  }

  struct Case: Decodable {
    let entry: Int
    let location: String
    let source: String
    let flags: String
    let operation: Operation
    let inputs: [Input]
  }

  struct Operation: Decodable {
    let kind: String
    let template: String?
  }

  struct Input: Decodable {
    let t: String
    let m: [Int]
    let g: [[String?]]?
    let o: [Int]
    let r: String?
    let s: [String]?
  }

  private static let fixture = Result { try ReferenceFixture.decode(Fixture.self, from: "regex/cases.json") }

  private static let properties: [(String, JSRegexProperty)] = [
    ("\\p{L}", .letter), ("\\p{N}", .number), ("\\p{Lu}", .uppercaseLetter), ("\\p{Script=Han}", .script(.han)), ("\\p{Script=Hiragana}", .script(.hiragana)),
    ("\\p{Script=Katakana}", .script(.katakana)), ("\\p{Script=Thai}", .script(.thai)),
  ]

  @Test func shouldMatchBunOnEveryInputOfEveryReferenceEntry() throws {
    let fixture = try Self.fixture.get()
    var differences: [String] = []
    for regexCase in fixture.cases {
      let regex = try JSRegex(regexCase.source, flags: regexCase.flags)
      for input in regexCase.inputs {
        for difference in Self.differences(regex, regexCase.operation, input) where differences.count < 40 {
          differences.append("\(regexCase.location) /\(regexCase.source)/\(regexCase.flags) \(difference) on \(describe(input.t))")
        }
      }
    }
    #expect(differences.isEmpty, "\(differences.joined(separator: "\n"))")
  }

  @Test func shouldCoverEveryEntryWithInputsThatMatch() throws {
    let fixture = try Self.fixture.get()
    let entries = try RegexCatalog.entries()
    #expect(Set(fixture.cases.map(\.entry)) == Set(entries.indices))
    for (index, entry) in entries.enumerated() {
      let inputs = fixture.cases.filter { $0.entry == index }.flatMap(\.inputs)
      #expect(fixture.cases.allSatisfy { $0.entry != index || $0.location == entry.location })
      #expect(inputs.count >= 32, "\(entry.location) has \(inputs.count) inputs")
      guard !entry.location.hasSuffix("passage-context.ts:36") else { continue }
      let matching = inputs.filter { !$0.m.isEmpty }.count
      #expect(Double(matching) >= 0.25 * Double(inputs.count), "\(entry.location) matches \(matching) of \(inputs.count)")
    }
  }

  @Test func shouldHoldBunsPropertyMembersForEveryCodePoint() async throws {
    let recorded = try Self.fixture.get().unicode.properties
    let swift = await withTaskGroup(of: (Int, [Int]).self) { group in
      for (index, (_, property)) in Self.properties.enumerated() { group.addTask { (index, Self.ranges(of: property)) } }
      var ranges: [Int: [Int]] = [:]
      for await (index, found) in group { ranges[index] = found }
      return ranges
    }
    for (index, (pattern, _)) in Self.properties.enumerated() { #expect(swift[index] == recorded[pattern], "\(pattern)") }
  }

  @Test func shouldFoldEveryCaseRelatedPairAsBunDoes() throws {
    let pairs = try Self.fixture.get().unicode.foldPairs.split(separator: " ")
    var differing: [String] = []
    for pair in pairs {
      let parts = pair.split(separator: ":")
      guard parts.count == 3, let first = UInt32(parts[0], radix: 16), let second = UInt32(parts[1], radix: 16) else { throw Mismatch(description: "bad pair \(pair)") }
      for (unicode, verdict) in zip([false, true], parts[2]) where verdict != "-" {
        let equal = JSCaseFolding.canonical(first, unicode: unicode) == JSCaseFolding.canonical(second, unicode: unicode)
        if equal != (verdict == "1") { differing.append("\(pair) \(unicode ? "iu" : "i")") }
      }
    }
    #expect(pairs.count > 1_000)
    #expect(differing.isEmpty, "\(differing)")
  }

  private static func differences(_ regex: JSRegex, _ operation: Operation, _ input: Input) -> [String] {
    let text = input.t
    let matches = text.jsMatchAll(regex)
    var found: [String] = []
    if matches.flatMap({ [$0.index, $0.endIndex] }) != input.m { found.append("matches \(matches.map { [$0.index, $0.endIndex] }) but bun \(input.m)") }
    let groups = matches.map { match in match.groups.map { group in group.map { JSString($0) } } }
    let recorded = input.g.map { all in all.map { match in match.map { group in group.map { JSString($0) } } } }
    if let recorded, groups != recorded { found.append("groups \(groups) but bun \(recorded)") }
    if recorded == nil, !groups.allSatisfy({ $0.isEmpty }) { found.append("groups \(groups) but bun none") }
    let derived = [regex.test(text) ? 1 : 0, regex.exec(text)?.index ?? -1, text.jsSearch(regex)]
    if derived != input.o { found.append("test, exec, search \(derived) but bun \(input.o)") }
    switch operation.kind {
    case "replace":
      let replaced = text.jsReplace(regex, operation.template ?? "")
      if input.r.map(replaced.jsEquals) != true { found.append("replace \(describe(replaced)) but bun \(describe(input.r ?? "nil"))") }
    case "replaceFunction":
      let replaced = text.jsReplace(regex) { "<\($0.index)>" }
      if input.r.map(replaced.jsEquals) != true { found.append("replace \(describe(replaced)) but bun \(describe(input.r ?? "nil"))") }
    case "split":
      let pieces = text.jsSplit(regex)
      if input.s.map({ recorded in recorded.map { JSString($0) } }) != pieces.map({ JSString($0) }) {
        found.append("split \(pieces.map(describe)) but bun \((input.s ?? []).map(describe))")
      }
    default:
      break
    }
    return found
  }

  private static func ranges(of property: JSRegexProperty) -> [Int] {
    var ranges: [Int] = []
    var start = -1
    for value in 0...0x11_0000 {
      let inside = value < 0x11_0000 && property.contains(UInt32(value))
      if inside, start < 0 { start = value }
      if !inside, start >= 0 {
        ranges += [start, value - 1]
        start = -1
      }
    }
    return ranges
  }
}
