import Foundation
import Testing

@testable import NovelForgeCore

/// Work is counted in matcher steps rather than timed, so the bounds hold on any machine and in a debug build.
struct JSRegexGrowthTests {
  struct Probe: Sendable, CustomTestStringConvertible {
    let location: String
    let source: String
    let flags: String
    let prefix: String
    let repeated: String
    let suffix: String
    let exponent: Int
    /// Steps per nᵉ on n repetitions; bun is quadratic on the quadratic inputs too.
    let budget: Double

    var testDescription: String { "\(location) on \(prefix)\(repeated)×n\(suffix)" }

    func steps(_ length: Int) throws -> Int {
      var machine = try JSRegex(source, flags: flags).machine(for: (prefix + String(repeating: repeated, count: length) + suffix).jsCodeUnits)
      _ = machine.allMatches()
      return machine.steps
    }
  }

  static let dialogueTag = "[\"”]\\s*,?\\s*(?:[A-Z][a-z]+(?:\\s[A-Z][a-z]+)?\\s)?(\(RegexCatalog.dialogueTagVerbs.joined(separator: "|")))\\b"

  static let probes = [
    Probe(
      location: "deterministic-metrics.ts:221", source: "[^.!?]+[.!?]+(?=\\s|$)|[^.!?]+$", flags: "g", prefix: "", repeated: "a", suffix: ".b", exponent: 2, budget: 1.5),
    Probe(location: "deterministic-metrics.ts:313", source: "[.!?]+[\"'”’)\\]]*(?=\\s|$)", flags: "g", prefix: "", repeated: ".", suffix: "x", exponent: 2, budget: 0.75),
    Probe(
      location: "deterministic-metrics.ts:477",
      source: dialogueTag, flags: "gi", prefix: "\"",
      repeated: " ", suffix: "x", exponent: 2, budget: 0.75),
    Probe(
      location: "deterministic-metrics.ts:477", source: dialogueTag, flags: "gi", prefix: "", repeated: "\" x", suffix: "", exponent: 1, budget: 50),
  ]

  @Test(arguments: probes)
  func shouldGrowNoFasterThanItsExponentWithinItsBudget(_ probe: Probe) throws {
    let small = try probe.steps(300)
    let large = try probe.steps(1_200)
    let growth = pow(4, Double(probe.exponent))
    #expect(Double(large) <= 1.03 * growth * Double(small), "\(small) steps at 300, \(large) at 1,200")
    #expect(Double(large) <= probe.budget * pow(1_200, Double(probe.exponent)), "\(large) steps at 1,200")
  }
}
