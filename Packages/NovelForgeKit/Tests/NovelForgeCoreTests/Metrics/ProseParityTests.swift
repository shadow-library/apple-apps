import Testing

@testable import NovelForgeCore

struct ProseParityTests {
  @Test func shouldMatchTheReferenceProseExtraction() throws {
    let cases = try MetricsFixtures.load("prose.json").map { try #require($0.arrayValue) }
    #expect(cases.count > 100)
    for (index, row) in cases.enumerated() {
      let split = ChapterProse.split(row[0].text)
      #expect(split.prose.jsEquals(row[1].text), "prose of case \(index)")
      #expect(split.unclosedFence?.jsEquals(row[2].text) ?? (row[2] == .null), "fence of case \(index)")
      #expect(ChapterProse.proseOnly(row[0].text).jsEquals(row[1].text))
    }
  }
}

struct TextMetricsParityTests {
  @Test func shouldMatchTheReferenceWordCounts() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("sentences.json"), 0)
    #expect(rows.count > 60)
    for (index, row) in rows.enumerated() { #expect(ProseMetrics.countWords(row[0].text) == row[1].int, "case \(index)") }
  }

  @Test func shouldMatchTheReferenceSentenceSplit() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("sentences.json"), 1)
    for (index, row) in rows.enumerated() { #expect(OrderedJSON.strings(ProseMetrics.splitSentences(row[0].text)) == row[1], "case \(index)") }
  }

  @Test func shouldMatchTheReferenceSentenceLengthMetrics() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("sentences.json"), 2)
    for (index, row) in rows.enumerated() { #expect(ProseMetrics.computeSentenceLengthMetrics(row[0].text).json == row[1], "case \(index)") }
  }

  @Test func shouldMatchTheReferenceParagraphSplit() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("sentences.json"), 3)
    for (index, row) in rows.enumerated() { #expect(OrderedJSON.strings(ProseMetrics.splitProseParagraphs(row[0].text)) == row[1], "case \(index)") }
  }

  @Test func shouldMatchTheReferenceReadability() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("readability.json"), 0)
    var custom = 0
    for (index, row) in rows.enumerated() {
      let actual: ReadabilityMetrics
      if row[1] == .null {
        actual = ProseMetrics.computeReadabilityMetrics(row[0].text)
      } else {
        custom += 1
        let patterns = try row[1].items.map { source in
          OrnatePattern(label: source.items[0].text, pattern: try JSRegex(source.items[1].text, flags: source.items[2].text))
        }
        actual = ProseMetrics.computeReadabilityMetrics(row[0].text, patterns: patterns)
      }
      #expect(actual.json == row[2], "case \(index)")
    }
    #expect(custom > 0)
  }

  @Test func shouldMatchTheReferenceSyllableCounts() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("readability.json"), 1)
    for (index, row) in rows.enumerated() { #expect(ProseMetrics.countSyllables(row[0].text) == row[1].int, "case \(index)") }
  }
}

struct NgramParityTests {
  @Test func shouldMatchTheReferenceTokens() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("ngrams.json"), 0)
    for (index, row) in rows.enumerated() { #expect(OrderedJSON.strings(ProseMetrics.tokenizeWords(row[0].text)) == row[1], "case \(index)") }
  }

  @Test func shouldMatchTheReferenceNgrams() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("ngrams.json"), 1)
    for (index, row) in rows.enumerated() {
      #expect(OrderedJSON.strings(ProseMetrics.ngrams(row[0].items.map(\.text), row[1].int)) == row[2], "case \(index)")
    }
  }

  @Test func shouldMatchTheReferenceWithinChapterRepetition() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("ngrams.json"), 2)
    for (index, row) in rows.enumerated() {
      let sizes = row[1] == .null ? ProseMetrics.ngramSizes : row[1].items.map(\.int)
      #expect(ProseMetrics.computeWithinChapterRepeatedNgrams(row[0].text, sizes: sizes).json == row[2], "case \(index)")
    }
  }

  @Test func shouldMatchTheReferenceCrossChapterRepetition() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("ngrams.json"), 3)
    for (index, row) in rows.enumerated() {
      let sizes = row[2] == .null ? ProseMetrics.ngramSizes : row[2].items.map(\.int)
      #expect(ProseMetrics.computeCrossChapterRepeatedNgrams(row[0].text, priorBodies: row[1].items.map(\.text), sizes: sizes).json == row[3], "case \(index)")
    }
  }
}

struct PhraseParityTests {
  @Test func shouldMatchTheReferenceStockPhraseCounts() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("phrases.json"), 0)
    for (index, row) in rows.enumerated() {
      let actual: StockPhraseReport
      if row[1] == .null {
        actual = ProseMetrics.computeStockPhraseCounts(row[0].text)
      } else {
        let phrases = try row[1].items.map { StockPhrase(label: $0.items[0].text, pattern: try JSRegex($0.items[1].text, flags: $0.items[2].text)) }
        actual = ProseMetrics.computeStockPhraseCounts(row[0].text, phrases: phrases)
      }
      #expect(actual.json == row[2], "case \(index)")
    }
  }

  @Test func shouldMatchTheReferenceDialogueTags() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("phrases.json"), 1)
    for (index, row) in rows.enumerated() { #expect(ProseMetrics.computeDialogueTagMetrics(row[0].text).json == row[1], "case \(index)") }
  }

  @Test func shouldMatchTheReferenceContractionRates() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("phrases.json"), 2)
    var thrown = 0
    for (index, row) in rows.enumerated() {
      if row[1] == .null {
        #expect(ProseMetrics.computeDialogueContractionRate(row[0].text).json == row[2], "case \(index)")
        continue
      }
      let pairs = row[1].items.map { ContractionPair(contracted: $0.items[0].text, expanded: $0.items[1].text) }
      do {
        let matchers = try ContractionMatchers(pairs: pairs)
        #expect(ProseMetrics.computeDialogueContractionRate(row[0].text, matchers: matchers).json == row[2], "case \(index)")
      } catch {
        thrown += 1
        #expect(row[2] == .string("throws"), "case \(index)")
      }
    }
    #expect(thrown > 0)
  }
}

struct ReportParityTests {
  @Test func shouldMatchTheReferenceEndingModeDistribution() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("reports.json"), 0)
    for (index, row) in rows.enumerated() {
      let entries = row[0].items.map { EndingModeEntry(chapter: $0["chapter"]?.int ?? 0, hookType: $0["hookType"]?.stringValue) }
      #expect(ProseMetrics.computeEndingModeDistribution(entries).json == row[1], "case \(index)")
    }
  }

  @Test func shouldMatchTheReferenceWordTargetResolution() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("reports.json"), 1)
    for (index, row) in rows.enumerated() {
      let source = row[0].objectValue.map { WordTargetSource(wordTargetMin: $0["wordTargetMin"]?.numberValue, wordTargetMax: $0["wordTargetMax"]?.numberValue) }
      #expect(ResolvedWordTarget.resolve(source).json == row[1], "case \(index)")
    }
  }

  @Test func shouldMatchTheReferenceWordCountDistribution() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("reports.json"), 2)
    for (index, row) in rows.enumerated() {
      let chapters = row[0].items.map { ChapterBody(chapter: $0["chapter"]?.int ?? 0, body: $0["body"]?.text ?? "") }
      let target = row[1] == .null ? ResolvedWordTarget.resolve() : ResolvedWordTarget(json: row[1])
      #expect(ProseMetrics.computeWordCountDistribution(chapters, target: target).json == row[2], "case \(index)")
    }
  }

  @Test func shouldMatchTheReferenceChapterMetrics() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("reports.json"), 3)
    for (index, row) in rows.enumerated() {
      let report = ProseMetrics.computeChapterMetrics(ChapterMetricsInput(json: row[0]), priorBodies: row[1].items.map(\.text))
      #expect(report.json == row[2], "case \(index)")
    }
  }

  @Test func shouldMatchTheReferenceDeterministicReport() throws {
    let rows = try MetricsFixtures.section(MetricsFixtures.load("reports.json"), 4)
    for (index, row) in rows.enumerated() {
      var priors: [Int: [String]] = [:]
      for entry in row[1].items { priors[entry.items[0].int] = entry.items[1].items.map(\.text) }
      let target = row[2] == .null ? ResolvedWordTarget.resolve() : ResolvedWordTarget(json: row[2])
      let report = ProseMetrics.computeDeterministicMetricsReport(row[0].items.map(ChapterMetricsInput.init(json:)), priorBodiesByChapter: priors, target: target)
      #expect(report.json == row[3], "case \(index)")
    }
  }
}
