import Testing

@testable import NovelForgeCore

private struct Fixture: Decodable {
  struct Corpus: Decodable {
    let id: String
    let category: String
    let text: String
    let o200k: Int
    let estimate: Int
  }

  struct Band: Decodable {
    let category: String
    let minRatio: Double
    let maxRatio: Double
  }

  struct Truncated: Decodable {
    let text: String
    let truncated: Bool
  }

  struct Case: Decodable {
    let maxTokens: Int
    let head: Truncated
    let tail: Truncated
    let leading: String
    let trailing: String
  }

  struct Text: Decodable {
    let id: String
    let text: String
    let cases: [Case]
  }

  struct Section: Decodable, BudgetedSection {
    let key: String
    let tokens: Int
    let requiredFlag: Bool?
    let priority: Int?

    var required: Bool { requiredFlag ?? false }

    private enum CodingKeys: String, CodingKey {
      case key, tokens, priority
      case requiredFlag = "required"
    }
  }

  struct Omission: Decodable {
    let key: String
    let reason: String
    let tokens: Int?
  }

  struct Budget: Decodable {
    let sections: [Section]
    let budget: Int
    let fitting: [Int]
    let omitted: [Omission]
  }

  let corpus: [Corpus]
  let bands: [Band]
  let truncation: [Text]
  let budgets: [Budget]

  static let shared = Result { try ReferenceFixture.decode(Fixture.self, from: "token-budget/token-budget.json") }
}

struct TokenBudgetEstimatorTests {
  @Test func shouldCountTheRecordedCorpusAsTheGeneratorEstimator() throws {
    for entry in try Fixture.shared.get().corpus { #expect(countTokens(entry.text) == entry.estimate, "\(entry.id)") }
  }

  @Test func shouldKeepEstimatesWithinTheStatedBandOfO200kBase() throws {
    let corpus = try Fixture.shared.get().corpus
    let tight = ["narrative", "prose", "prose-long", "emoji", "identifiers", "mixed"]
    let loose = ["cjk", "cyrillic-accents-arabic", "code", "digits"]
    for entry in corpus {
      let ratio = Double(countTokens(entry.text)) / Double(entry.o200k)
      if tight.contains(entry.category) {
        #expect(ratio >= 1.0 && ratio <= 1.35, "\(entry.id) ratio \(ratio)")
      } else if loose.contains(entry.category) {
        #expect(ratio >= 0.95 && ratio <= 1.5, "\(entry.id) ratio \(ratio)")
      } else if entry.category == "whitespace" {
        #expect(ratio >= 1.1, "\(entry.id) ratio \(ratio)")
      } else {
        #expect(ratio >= 0.85 && ratio <= 1.0, "\(entry.id) ratio \(ratio)")
      }
    }
  }

  @Test func shouldRecordTheBandsTheEstimatorStaysWithin() throws {
    let fixture = try Fixture.shared.get()
    for band in fixture.bands {
      let ratios = fixture.corpus.filter { $0.category == band.category }.map { Double(countTokens($0.text)) / Double($0.o200k) }
      #expect(abs((ratios.min() ?? 0) - band.minRatio) < 0.001, "\(band.category) min")
      #expect(abs((ratios.max() ?? 0) - band.maxRatio) < 0.001, "\(band.category) max")
    }
  }

  @Test func shouldNeverCountMoreThanTheLongerPrefix() throws {
    for entry in try Fixture.shared.get().corpus {
      let scalars = Array(entry.text.unicodeScalars)
      var previous = 0
      for length in stride(from: 0, through: scalars.count, by: max(1, scalars.count / 40)) {
        var prefix = String.UnicodeScalarView()
        prefix.append(contentsOf: scalars[..<length])
        let count = countTokens(String(prefix))
        #expect(count >= previous, "\(entry.id) at \(length)")
        previous = count
      }
    }
  }

  @Test func shouldNeverCountMoreThanTheLongerSuffix() throws {
    for entry in try Fixture.shared.get().corpus {
      let scalars = Array(entry.text.unicodeScalars)
      var previous = 0
      for length in stride(from: 0, through: scalars.count, by: max(1, scalars.count / 40)) {
        var suffix = String.UnicodeScalarView()
        suffix.append(contentsOf: scalars[(scalars.count - length)...])
        let count = countTokens(String(suffix))
        #expect(count >= previous, "\(entry.id) at \(length)")
        previous = count
      }
    }
  }

  @Test func shouldNeverCountLessAsAWordGrows() {
    for unit in ["x", "7", " ", "\n", "!", "é", "漢", "😀"] {
      var previous = 0
      for length in 1...120 {
        let count = countTokens(String(repeating: unit, count: length))
        #expect(count >= previous, "\(unit) x \(length)")
        previous = count
      }
    }
  }

  @Test func shouldCountEdgeInputs() {
    #expect(countTokens("") == 0)
    #expect(countTokens(" ") == 0)
    #expect(countTokens("\n\n") == 2)
    #expect(countTokens("\r\n") == 2)
    #expect(countTokens(String(repeating: " ", count: 1000)) == 51)
    #expect(countTokens("a") == 2)
    #expect(countTokens("😀") == 3)
    #expect(countTokens("a\u{0301}") == 3)
    #expect(countTokens(String(repeating: "x", count: 1_000_000)) == 81_251)
  }
}

struct TokenBudgetTruncationParityTests {
  @Test func shouldTruncateAtParagraphHeadAsTheReference() throws {
    var truncated = 0
    for text in try Fixture.shared.get().truncation {
      for item in text.cases {
        let result = truncateAtParagraph(text.text, maxTokens: item.maxTokens)
        #expect(result.text.jsEquals(item.head.text) && result.truncated == item.head.truncated, "\(text.id) head \(item.maxTokens)")
        if result.truncated { truncated += 1 }
      }
    }
    #expect(truncated > 100)
  }

  @Test func shouldTruncateAtParagraphTailAsTheReference() throws {
    for text in try Fixture.shared.get().truncation {
      for item in text.cases {
        let result = truncateAtParagraphTail(text.text, maxTokens: item.maxTokens)
        #expect(result.text.jsEquals(item.tail.text) && result.truncated == item.tail.truncated, "\(text.id) tail \(item.maxTokens)")
      }
    }
  }

  @Test func shouldCutLeadingAndTrailingCharsAsTheReference() throws {
    for text in try Fixture.shared.get().truncation {
      for item in text.cases {
        #expect(leadingChars(text.text, maxTokens: item.maxTokens).jsEquals(item.leading), "\(text.id) leading \(item.maxTokens)")
        #expect(trailingChars(text.text, maxTokens: item.maxTokens).jsEquals(item.trailing), "\(text.id) trailing \(item.maxTokens)")
      }
    }
  }
}

struct TokenBudgetTruncationEdgeTests {
  @Test func shouldTruncateEverythingAtZeroBudget() {
    #expect(truncateAtParagraph("hello", maxTokens: 0) == TruncatedText(text: "", truncated: true))
    #expect(truncateAtParagraphTail("hello", maxTokens: 0) == TruncatedText(text: "", truncated: true))
    #expect(truncateAtParagraph("", maxTokens: 0).truncated)
  }

  @Test func shouldKeepEmptyAndWhitespaceTextWhole() {
    #expect(truncateAtParagraph("", maxTokens: 5) == TruncatedText(text: "", truncated: false))
    #expect(truncateAtParagraph("   ", maxTokens: 5) == TruncatedText(text: "   ", truncated: false))
    #expect(truncateAtParagraphTail("\n\n", maxTokens: 5) == TruncatedText(text: "", truncated: false))
  }

  @Test func shouldCutASingleHugeParagraphAtWordBoundaries() {
    let text = Array(repeating: "word", count: 5000).joined(separator: " ")
    let head = truncateAtParagraph(text, maxTokens: 100)
    let tail = truncateAtParagraphTail(text, maxTokens: 100)
    #expect(head.truncated && tail.truncated)
    #expect(countTokens(head.text) <= 100 && countTokens(tail.text) <= 100)
    #expect(head.text.jsLength > 100 && head.text.jsSplit(" ").allSatisfy { $0 == "word" })
    #expect(tail.text.jsSplit(" ").allSatisfy { $0 == "word" })
  }

  @Test func shouldCutAnUnbrokenWordByCharacter() {
    let word = String(repeating: "q", count: 4000)
    #expect(truncateAtParagraph(word, maxTokens: 30).text == String(repeating: "q", count: 361))
    #expect(truncateAtParagraphTail(word, maxTokens: 30).text == String(repeating: "q", count: 361))
  }

  @Test func shouldTreatCRLFParagraphBreaksAsOneParagraph() {
    let text = "first paragraph\r\n\r\nsecond paragraph"
    #expect(truncateAtParagraph(text, maxTokens: 1000) == TruncatedText(text: text, truncated: false))
    #expect(truncateAtParagraph(text, maxTokens: 2).text.jsEquals("first"))
  }

  @Test func shouldJoinParagraphsWithOneBlankLine() {
    let result = truncateAtParagraph("alpha\n\n\n\nbeta\n\ngamma", maxTokens: 1000)
    #expect(result == TruncatedText(text: "alpha\n\nbeta\n\ngamma", truncated: false))
  }

  @Test func shouldKeepAstralCharactersWholeWhenCutting() {
    let emoji = String(repeating: "😀", count: 50)
    let cut = leadingChars(emoji, maxTokens: 9)
    #expect(cut == String(repeating: "😀", count: 3))
    #expect(trailingChars(emoji, maxTokens: 9) == cut)
    #expect(leadingChars(emoji, maxTokens: 2) == "")
    #expect(leadingChars("", maxTokens: 5) == "")
  }

  @Test func shouldReturnNothingForNegativeBudgets() {
    #expect(leadingChars("abc", maxTokens: -1) == "")
    #expect(truncateAtParagraph("abc", maxTokens: -1) == TruncatedText(text: "", truncated: true))
  }
}

private struct Piece: BudgetedSection {
  let key: String
  let tokens: Int
  var required = false
  var priority: Int?
}

struct TokenBudgetApplyTests {
  @Test func shouldApplyTheBudgetAsTheReference() throws {
    var dropped = 0
    var forced = 0
    for (position, item) in try Fixture.shared.get().budgets.enumerated() {
      let result = applyBudget(item.sections, budgetTokens: item.budget)
      let expected = item.fitting.map { item.sections[$0] }
      #expect(result.fitting.count == expected.count && zip(result.fitting, expected).allSatisfy { $0.key.jsEquals($1.key) && $0.tokens == $1.tokens }, "fitting \(position)")
      #expect(result.omitted.count == item.omitted.count, "omitted \(position)")
      for (actual, reference) in zip(result.omitted, item.omitted) {
        #expect(actual.key.jsEquals(reference.key) && actual.reason.rawValue == reference.reason && actual.tokens == reference.tokens, "omission \(position)")
      }
      if !item.omitted.isEmpty { dropped += 1 }
      if item.fitting.count == 1 && item.budget > 0 && item.sections.count > 1 { forced += 1 }
    }
    #expect(dropped > 100)
    #expect(forced > 5)
  }

  @Test func shouldChargeRequiredSectionsBeforeAnyOtherCompetes() {
    let sections = [Piece(key: "prefix", tokens: 90), Piece(key: "input", tokens: 60, required: true)]
    let result = applyBudget(sections, budgetTokens: 100)
    #expect(result.fitting.map(\.key) == ["input"])
    #expect(result.omitted == [BudgetOmission(key: "prefix", reason: .budget, tokens: 90)])
  }

  @Test func shouldClaimBudgetByPriorityThenListOrderAndRenderInListOrder() {
    let sections = [Piece(key: "a", tokens: 40), Piece(key: "b", tokens: 40, priority: 1), Piece(key: "c", tokens: 40, priority: 1), Piece(key: "d", tokens: 40, priority: 0)]
    let result = applyBudget(sections, budgetTokens: 85)
    #expect(result.fitting.map(\.key) == ["b", "d"])
    #expect(result.omitted.map(\.key) == ["c", "a"])
  }

  @Test func shouldForceTheFirstSectionWhenNothingFits() {
    let sections = [Piece(key: "a", tokens: 500), Piece(key: "b", tokens: 600)]
    let result = applyBudget(sections, budgetTokens: 10)
    #expect(result.fitting.map(\.key) == ["a"])
    #expect(result.omitted.map(\.key) == ["b"])
  }

  @Test func shouldKeepNothingForAnEmptyListOrAZeroBudget() {
    #expect(applyBudget([Piece](), budgetTokens: 10).fitting.isEmpty)
    let result = applyBudget([Piece(key: "a", tokens: 5)], budgetTokens: 0)
    #expect(result.fitting.isEmpty)
    #expect(result.omitted == [BudgetOmission(key: "a", reason: .budget, tokens: 5)])
  }
}
