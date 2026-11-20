import ShadowTestSupport
import Testing

@testable import ShadowText

struct JSRegexDifferentialTests {
  static let inputsPerCase = 200
  static let minimumMatchingShare = 0.25
  static let genericTemplate = "<$&|$1|$$|$2$10|$0|$<x>|$>"
  static let chunkCount = 8
  static let operations = ["matchAll", "test", "exec", "search", "replace(call site)", "replace(template)", "replace(function)", "split", "split(limit 2)"]

  /// Where the system JavaScriptCore misreads `[\p{L}\p{N}_]` (astral members in lookbehind, folds under `iu`); `JSRegexBunFixtureTests` covers these.
  static let excluded = ["writer-disclosure-policy.ts:89", "writer-disclosure-policy.ts:100", "reveal-term.ts:15"]

  static let evaluate = """
    (source, flags, inputs, siteTemplate, genericTemplate) => {
      const re = new RegExp(source, flags);
      const all = new RegExp(source, flags.includes('g') ? flags : flags + 'g');
      const groups = m => m.slice(1).map(g => g === undefined ? null : g);
      const pieces = parts => parts.map(part => part === undefined ? '' : part);
      return inputs.map(text => {
        const matches = [...text.matchAll(all)].map(m => [m.index, m[0], groups(m)]);
        re.lastIndex = 0;
        const test = re.test(text);
        re.lastIndex = 0;
        const exec = re.exec(text);
        re.lastIndex = 0;
        return [
          matches, test, exec === null ? null : [exec.index, exec[0], groups(exec)], text.search(re),
          text.replace(re, siteTemplate), text.replace(re, genericTemplate), text.replace(re, (...args) => `{${args[args.length - 2]}:${args[0]}:${args.length}}`),
          pieces(text.split(re)), pieces(text.split(re, 2)),
        ];
      });
    }
    """

  static func swiftResults(_ regex: JSRegex, _ text: String, siteTemplate: String) -> [JSOracleValue] {
    func encoded(_ match: JSRegexMatch) -> JSOracleValue {
      .array([match.index.oracleValue, match.text.oracleValue, .array(match.groups.map { $0?.oracleValue ?? .null })])
    }
    return [
      .array(text.jsMatchAll(regex).map(encoded)), regex.test(text).oracleValue, regex.exec(text).map(encoded) ?? .null, text.jsSearch(regex).oracleValue,
      text.jsReplace(regex, siteTemplate).oracleValue, text.jsReplace(regex, genericTemplate).oracleValue,
      text.jsReplace(regex) { "{\($0.index):\($0.text):\($0.groups.count + 3)}" }.oracleValue, text.jsSplit(regex).oracleValue, text.jsSplit(regex, limit: 2).oracleValue,
    ]
  }

  static func isExcluded(_ location: String) -> Bool {
    excluded.contains { location.hasSuffix("/" + $0) }
  }

  static func cases(inChunk chunk: Int) throws -> [RegexCase] {
    try RegexCatalog.cases().filter { !isExcluded($0.location) }.enumerated().filter { $0.offset % chunkCount == chunk }.map(\.element)
  }

  @Test(arguments: 0..<chunkCount)
  func shouldMatchJavaScriptForEveryReferenceRegex(chunk: Int) throws {
    let oracle = try JSOracle()
    var differences: [String] = []
    var matchedInputs: [String: (matched: Int, total: Int)] = [:]
    for regexCase in try Self.cases(inChunk: chunk) {
      let regex: JSRegex
      do {
        regex = try JSRegex(regexCase.source, flags: regexCase.flags)
      } catch {
        differences.append("\(regexCase): refused (\(error))")
        continue
      }
      let inputs = try Self.inputs(for: regexCase)
      let perInput = try Self.oracleResults(oracle, regexCase, inputs)
      var caseDifferences = 0
      for (text, javaScript) in zip(inputs, perInput) {
        guard case .array(let results) = javaScript else { throw Mismatch(description: "\(regexCase): unexpected oracle output") }
        let swift = Self.swiftResults(regex, text, siteTemplate: regexCase.siteTemplate)
        for (operation, (mine, theirs)) in zip(Self.operations, zip(swift, results)) where mine != theirs.droppingLoneSurrogates {
          caseDifferences += 1
          if caseDifferences <= 3 { differences.append("\(regexCase) \(operation) on \(describe(text)): Swift \(mine) but JavaScript \(theirs)") }
        }
        if case .array(let matches) = results.first, !matches.isEmpty || regexCase.location.hasSuffix("passage-context.ts:36") {
          matchedInputs[regexCase.location, default: (0, 0)].matched += 1
        }
        matchedInputs[regexCase.location, default: (0, 0)].total += 1
      }
    }
    #expect(differences.isEmpty, "\(differences.count) differences:\n\(differences.joined(separator: "\n"))")
    let starved = matchedInputs.filter { Double($0.value.matched) < Self.minimumMatchingShare * Double($0.value.total) }
    #expect(starved.isEmpty, "entries verified on inputs that rarely match: \(starved.map { "\($0.key) \($0.value.matched)/\($0.value.total)" }.sorted())")
    #expect(!matchedInputs.isEmpty)
  }

  static func oracleResults(_ oracle: JSOracle, _ regexCase: RegexCase, _ inputs: [String]) throws -> [JSOracleValue] {
    let output = try oracle.call(evaluate, .string(regexCase.source), .string(regexCase.flags), .strings(inputs), .string(regexCase.siteTemplate), .string(genericTemplate))
    guard case .array(let perInput) = output, perInput.count == inputs.count else { throw Mismatch(description: "\(regexCase): unexpected oracle output") }
    return perInput
  }

  @Test func shouldCoverEveryEntryOfTheFixtureWithAtLeastTwoHundredInputs() throws {
    let entries = try RegexCatalog.entries()
    let cases = try RegexCatalog.cases()
    #expect(entries.count == 127)
    for (index, entry) in entries.enumerated() where !Self.isExcluded(entry.location) {
      let count = cases.filter { $0.entry == index }.count
      #expect(count * Self.inputsPerCase >= 200, "\(entry.location) has \(count) cases")
    }
    #expect(Set(cases.map(\.file)).allSatisfy { file in RegexCatalog.files.contains { file.hasSuffix("/" + $0) } })
  }

  @Test func shouldBuildPassagePatternsExactlyAsTheReferenceDoes() throws {
    let oracle = try JSOracle()
    var generator = SeededGenerator(seed: 0x9A55)
    for _ in 0..<60 {
      let passage = (0..<generator.int(in: 1...6)).map { _ in generator.pick(from: RegexCatalog.termWords + TextSamples.pieces) }.joined(
        separator: generator.pick(from: [" ", "\n", "  "]))
      let text = generator.pick(from: ["", "- ", "3) "]) + passage + generator.pick(from: ["", ".", "!?"])
      try expectExactlySame(try PassagePattern.source(for: text), try oracle.call(PassagePattern.referenceBuilder, .string(text)), describe(text))
    }
  }

  static func inputs(for regexCase: RegexCase) throws -> [String] {
    let inputs = try RegexInputs(regexCase)
    var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: regexCase.description.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }))
    return (0..<inputsPerCase).map { _ in inputs.input(using: &generator) }
  }
}
