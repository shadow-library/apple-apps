import Testing

@testable import NovelForgeCore

struct MechanicalCheckDeviationTests {
  @Test func shouldDropTheHalfOfASurrogatePairAnExcerptCutsThrough() throws {
    let markdown = "```" + String(repeating: "😀", count: 60) + "\nafter"
    let findings = MechanicalCheck.checkDraftMechanics(markdown, target: ResolvedWordTarget(min: 1, max: 5, aim: 3))
    let fence = try #require(findings.first { $0.text.jsIncludes("the fence opened by") })
    let kept = "```" + String(repeating: "😀", count: 38)
    #expect(fence.text.jsEquals(MechanicalCheck.prefix + "the fence opened by \"\(kept)…\" is never closed, so the rest of the chapter renders inside it"))
    #expect(!fence.text.jsIncludes("\u{FFFD}"))
  }

  @Test func shouldTreatAnEmptyPreviousChapterAsAbsent() {
    #expect(MechanicalCheck.findBoundaryEcho("a b c d e f", "") == nil)
    #expect(MechanicalCheck.findBoundaryEcho("a b c d e f", nil) == nil)
    #expect(MechanicalCheck.findBoundaryEcho("a b c d e f", "x a b c d e f") == "a b c d e f")
  }
}

struct ReadabilityCheckDeviationTests {
  @Test func shouldDropTheHalfOfASurrogatePairAQuoteCutsThrough() {
    let sentence = String(repeating: "a ", count: 199) + "b😀 tail"
    let evidence = ReadabilityEvidence(
      metrics: ProseMetrics.computeReadabilityMetrics(""), overLimits: [], flagged: [FlaggedSentence(sentence: sentence, reason: "over 30 words")]
    )
    let rendered = ReadabilityCheck.renderReadabilityEvidence(evidence)
    let kept = String(repeating: "a ", count: 199) + "b"
    #expect(rendered.hasSuffix("1. \"\(kept)…\" (over 30 words)"))
    #expect(!rendered.jsIncludes("😀"))
  }
}
