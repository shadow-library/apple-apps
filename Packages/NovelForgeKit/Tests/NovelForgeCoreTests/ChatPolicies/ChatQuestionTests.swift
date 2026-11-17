import Testing

@testable import NovelForgeCore

private let allowedKeys = progressItemKeys.map(\.rawValue)

private func parse(_ json: String) throws -> OrderedJSON { try OrderedJSON(parsing: json) }

struct ChatQuestionParityTests {
  private static let fixture = Result { try ChatFixture.load("question.json") }

  @Test func shouldRenderTheWireSchemaAsTheReference() throws {
    #expect(chatQuestionWireSchema.jsonText.jsEquals(try #require(try Self.fixture.get()["wire"]).text))
  }

  @Test func shouldSanitizeEveryCandidateAsTheReference() throws {
    var kept = 0
    for (position, item) in try #require(try Self.fixture.get()["sanitize"]).items.enumerated() {
      let candidate = try item["candidate"].flatMap { $0.stringValue }.map(parse)
      let allowed = try #require(item["allowed"]).items.map(\.text)
      let result = sanitizeChatQuestion(candidate, allowedProgressKeys: allowed)
      #expect((result?.json.jsonText ?? "null").jsEquals(try #require(item["expected"]).text), "sanitize \(position)")
      if result != nil { kept += 1 }
    }
    #expect(kept > 20)
  }

  @Test func shouldRenderEveryQuestionForHistoryAsTheReference() throws {
    var rendered = 0
    for (position, item) in try #require(try Self.fixture.get()["history"]).items.enumerated() {
      let question = try item["question"].flatMap { $0.stringValue }.map(parse)
      let expected = item["expected"]?.stringValue
      let line = renderQuestionForHistory(question)
      #expect(line?.jsEquals(expected ?? "") ?? (expected == nil), "history \(position)")
      if line != nil { rendered += 1 }
    }
    #expect(rendered > 20)
  }
}

// apps/novel-forge-server/tests/refinement/chat-question.spec.ts:16
struct ChatQuestionSpecTests {
  private let valid =
    #"{"question":"Who opposes Mira?","why":"the reader needs someone to root against","answers":[{"title":"A rival guild","tradeOff":"crowds out the court politics","recommended":true},{"title":"A corrupt council","why":"raises the stakes citywide"}],"progressKey":"opposition"}"#

  private func sanitized(_ json: String) throws -> ChatQuestion? { sanitizeChatQuestion(try parse(json), allowedProgressKeys: allowedKeys) }

  @Test func shouldKeepAWellFormedQuestionAsItIs() throws {
    #expect(try sanitized(valid)?.json.jsonText == valid)
  }

  @Test func shouldDropAProgressKeyOutsideTheChecklistAndKeepEverythingElse() throws {
    let result = try sanitized(valid.replacing("opposition", with: "not-a-real-key"))
    #expect(result?.progressKey == nil)
    #expect(result?.answers.count == 2)
  }

  @Test func shouldDropTheWholeCardWhenItHasTooFewOrTooManyAnswers() throws {
    #expect(try sanitized(#"{"question":"x","answers":[{"title":"only one"}]}"#) == nil)
    let five = (0..<5).map { #"{"title":"answer \#($0)"}"# }.joined(separator: ",")
    #expect(try sanitized(#"{"question":"x","answers":[\#(five)]}"#) == nil)
  }

  @Test func shouldDropTheWholeCardWhenTheQuestionIsMissingOrBlank() throws {
    #expect(try sanitized(#"{"answers":[{"title":"a"},{"title":"b"}]}"#) == nil)
    #expect(try sanitized(#"{"question":"   ","answers":[{"title":"a"},{"title":"b"}]}"#) == nil)
  }

  @Test func shouldDropTheWholeCardWhenAnAnswerHasNoTitleOrABlankOne() throws {
    #expect(try sanitized(#"{"question":"x","answers":[{"title":"fine"},{"why":"no title here"}]}"#) == nil)
    #expect(try sanitized(#"{"question":"x","answers":[{"title":"fine"},{"title":"  "}]}"#) == nil)
  }

  @Test func shouldIgnoreANonBooleanRecommendedFlag() throws {
    let result = try sanitized(#"{"question":"x","answers":[{"title":"a","recommended":"yes"},{"title":"b"}]}"#)
    #expect(result?.answers.first?.json.jsonText == #"{"title":"a"}"#)
  }

  @Test func shouldRejectCandidatesThatAreNotObjects() throws {
    #expect(sanitizeChatQuestion(nil, allowedProgressKeys: allowedKeys) == nil)
    for text in [#""nonsense""#, "null", "[]", "4"] { #expect(try sanitized(text) == nil) }
    #expect(try sanitized(#"{"question":"x","answers":"not an array"}"#) == nil)
    #expect(try sanitized(#"{"question":"x","why":123,"answers":[{"title":"a"},{"title":"b"}]}"#)?.why == nil)
  }

  @Test func shouldListTheQuestionWithItsAnswerTitles() throws {
    #expect(renderQuestionForHistory(try parse(#"{"question":"Which way?","answers":[{"title":"North"},{"title":"South"}]}"#)) == "[Asked: Which way? — options: North / South]")
  }

  @Test func shouldBoundALongQuestionAndLongTitles() throws {
    let long = #"{"question":"\#(String(repeating: "word ", count: 100))","answers":[{"title":"\#(String(repeating: "long ", count: 40))"},{"title":"B"}]}"#
    #expect((renderQuestionForHistory(try parse(long))?.jsLength ?? 999) < 260)
  }

  @Test func shouldRenderNothingForAMalformedValue() throws {
    #expect(renderQuestionForHistory(nil) == nil)
    #expect(renderQuestionForHistory(try parse("null")) == nil)
    #expect(renderQuestionForHistory(try parse(#"{"question":3}"#)) == nil)
  }
}
