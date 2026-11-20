import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

struct QuoteRuleParityTests {
  private static let fixture = Result { try QuoteTextFixture.load() }

  @Test func shouldLoadEnoughTextAndQuoteCases() throws {
    let fixture = try Self.fixture.get()
    #expect(fixture.texts.count > 250)
    #expect(fixture.quotes.count > 450)
    #expect(fixture.texts.contains { $0.tokens.contains { token in String(decoding: token, as: UTF16.self).jsCodeUnits != token } })
    #expect(fixture.quotes.contains { $0.found && !$0.tentative })
    #expect(fixture.quotes.contains { $0.found && $0.tentative })
  }

  @Test func shouldNormaliseTokeniseAndSplitTextAsTheReference() throws {
    let rule = try #require(QuoteRule.shared)
    for item in try Self.fixture.get().texts {
      #expect(rule.normaliseForQuote(item.text).jsEquals(item.normalised), "normaliseForQuote(\(item.text.debugDescription))")
      #expect(rule.contentTokens(item.text) == item.tokens, "contentTokens(\(item.text.debugDescription))")
      let sentences = rule.splitSentences(item.text)
      #expect(CodeUnitStrings.equal(sentences, item.sentences), "splitSentences(\(item.text.debugDescription))")
      #expect(sentences.map(rule.sentenceIsTentative) == item.tentative, "sentenceIsTentative in \(item.text.debugDescription)")
      let words = rule.authorWords(item.text)
      #expect(words.stated == item.stated, "authorWords(\(item.text.debugDescription)).stated")
      #expect(words.hedged == item.hedged, "authorWords(\(item.text.debugDescription)).hedged")
    }
  }

  @Test func shouldFindQuotesAndJudgeThemTentativeAsTheReference() throws {
    let rule = try #require(QuoteRule.shared)
    for item in try Self.fixture.get().quotes {
      #expect(rule.quoteFoundIn(item.quote, item.text) == item.found, "quoteFoundIn(\(item.quote.debugDescription), \(item.text.debugDescription))")
      #expect(rule.quoteIsTentative(item.quote, item.text) == item.tentative, "quoteIsTentative(\(item.quote.debugDescription), \(item.text.debugDescription))")
    }
  }
}
