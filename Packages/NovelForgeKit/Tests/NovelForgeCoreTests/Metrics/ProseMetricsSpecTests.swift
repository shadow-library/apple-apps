import Testing

@testable import NovelForgeCore

struct ProseMetricsSpecTests {
  @Test func shouldCountEveryObjectPrototypeWordAsAnOwnHookType() {
    let words = ["constructor", "toString", "__proto__", "hasOwnProperty", "valueOf", "isPrototypeOf"]
    let distribution = ProseMetrics.computeEndingModeDistribution(words.enumerated().map { EndingModeEntry(chapter: $0.offset, hookType: $0.element) })
    #expect(distribution.total == words.count)
    #expect(distribution.distinctCount == words.count)
    #expect(distribution.counts.map(\.count) == Array(repeating: 1, count: words.count))
    #expect(distribution.counts.map(\.hookType) == words)
  }

  @Test func shouldTallyRepeatedPrototypeWordsFromOne() {
    let entries = ["constructor", "constructor", "__proto__", "__proto__"].map { EndingModeEntry(chapter: 1, hookType: $0) }
    #expect(ProseMetrics.computeEndingModeDistribution(entries).counts.map(\.count) == [2, 2])
  }

  @Test func shouldIgnoreEmptyAndMissingHookTypes() {
    let entries = [EndingModeEntry(chapter: 1, hookType: nil), EndingModeEntry(chapter: 2, hookType: ""), EndingModeEntry(chapter: 3, hookType: "a")]
    let distribution = ProseMetrics.computeEndingModeDistribution(entries)
    #expect(distribution.total == 1)
    #expect(distribution.distinctCount == 1)
  }

  @Test func shouldOrderIntegerLikeHookTypesFirst() {
    let entries = ["b", "10", "a", "2"].map { EndingModeEntry(chapter: 1, hookType: $0) }
    #expect(ProseMetrics.computeEndingModeDistribution(entries).counts.map(\.hookType) == ["2", "10", "b", "a"])
  }

  @Test func shouldKeepCanonicallyEquivalentHookTypesApart() {
    let entries = ["\u{E9}", "e\u{301}"].map { EndingModeEntry(chapter: 1, hookType: $0) }
    #expect(ProseMetrics.computeEndingModeDistribution(entries).distinctCount == 2)
  }

  @Test func shouldYieldNoNgramsForSizesBelowOne() {
    #expect(ProseMetrics.ngrams(["a", "b"], 0).isEmpty)
    #expect(ProseMetrics.ngrams(["a", "b"], -1).isEmpty)
    #expect(ProseMetrics.computeWithinChapterRepeatedNgrams("a b c", sizes: [0, -2]).sizes.map(\.totalOccurrences) == [0, 0])
  }

  @Test func shouldResolveTheDefaultTarget() {
    let target = ResolvedWordTarget.resolve()
    #expect(target == ResolvedWordTarget(min: 1800, max: 2600, aim: 2200))
    #expect(target.contains(1800) && target.contains(2600) && !target.contains(2601))
  }

  @Test func shouldTreatTheEcmaScriptWhitespaceSetAsSeparators() {
    #expect(ProseMetrics.countWords("a\u{A0}b\u{2028}c\u{FEFF}d") == 4)
    #expect(ProseMetrics.countWords("a\u{200B}b\u{180E}c\u{85}d") == 1)
    #expect(ProseMetrics.countWords(" \u{3000} ") == 0)
  }

  @Test func shouldReturnEmptyReportsForEmptyInput() {
    #expect(ProseMetrics.splitSentences("").isEmpty)
    #expect(ProseMetrics.computeReadabilityMetrics("").readingGrade == 0)
    #expect(ProseMetrics.computeWordCountDistribution([]).median == 0)
  }
}
