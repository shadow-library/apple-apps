import Foundation
import Testing

@testable import NovelForgeCore

private struct HoldsFixture: Decodable {
  struct Finding: Decodable {
    let severity: String
    let category: String
  }

  struct Case: Decodable {
    let verdict: String
    let findings: [Finding]
    let native: [Finding]
    let route: String
    let holds: Bool
    let lossy: Bool
  }

  let cases: [Case]
}

@Suite("Chapter lifecycle: generation pass parity")
struct LifecycleOutcomeParityTests {
  private static func findings(_ stored: [HoldsFixture.Finding]) -> [ReviewFinding] {
    stored.enumerated().map { offset, finding in
      ReviewFinding(id: "f\(offset + 1)", severity: StoredEnum(rawValue: finding.severity), category: StoredEnum(rawValue: finding.category), text: "", fingerprint: "")
    }
  }

  private static let fixture = Result { try ReferenceFixture.decode(HoldsFixture.self, from: "chapter-lifecycle/generation-holds.json") }

  // Fixtures/chapter-lifecycle/generate.ts: routeAfterJudge on the judge node's findings with repair off or spent, against the pass as the pipeline stores it.
  @Test func shouldHoldExactlyThePassesTheReferenceRoutedToReviewAsThePipelineStoresThem() throws {
    let cases = try Self.fixture.get().cases
    #expect(cases.count == 600)
    for (index, entry) in cases.enumerated() {
      #expect(ChapterLifecycle.outcomeHolds(verdict: entry.verdict, findings: Self.findings(entry.native)) == entry.holds, "case \(index): \(entry.route)")
    }
  }

  // review-findings.ts:206-224 categorises by text prefix and stores nothing for a non-compliant block without issues, so only some passes keep their route.
  @Test func shouldHoldTheReferenceStoredPassesWhoseFindingsStillTellTheRoute() throws {
    let cases = try Self.fixture.get().cases
    for (index, entry) in cases.enumerated() where !entry.lossy {
      #expect(ChapterLifecycle.outcomeHolds(verdict: entry.verdict, findings: Self.findings(entry.findings)) == entry.holds, "case \(index): \(entry.route)")
    }
    let lossy = cases.filter(\.lossy)
    #expect(!lossy.isEmpty)
    #expect(lossy.contains { ChapterLifecycle.outcomeHolds(verdict: $0.verdict, findings: Self.findings($0.findings)) != $0.holds })
  }

  @Test func shouldHoldAPassWithAFindingThisVersionCannotRead() {
    let unknown = ReviewFinding(id: "f1", severity: .known(.note), category: StoredEnum(rawValue: "tone"), text: "", fingerprint: "")
    #expect(ChapterLifecycle.outcomeHolds(verdict: "consistent", findings: [unknown]))
    #expect(ChapterLifecycle.outcomeHolds(verdict: nil, findings: []))
    #expect(!ChapterLifecycle.outcomeHolds(verdict: "consistent", findings: []))
  }
}
