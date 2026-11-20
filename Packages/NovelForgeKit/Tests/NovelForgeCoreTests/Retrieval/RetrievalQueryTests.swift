import Testing

@testable import NovelForgeCore

@Suite("Retrieval query", TestTimeLimit.quick)
struct RetrievalQueryTests {
  @Test func shouldQuoteEveryTermAndAddTheWholeQueryAsAPhrase() {
    #expect(RetrievalQuery("Mara's tower").matchExpression == #""Mara s tower" OR "Mara" OR "s" OR "tower""#)
    #expect(RetrievalQuery("tower").matchExpression == #""tower""#)
  }

  @Test(arguments: ["", "   ", "!!! ???", "\"\"", "* ^ : ( ) - +", "😀🌊", "\u{0000}\n\t"])
  func shouldHaveNoExpressionForAQueryWithoutTerms(_ text: String) {
    #expect(RetrievalQuery(text).matchExpression == nil)
  }

  @Test func shouldKeepFTSSyntaxOutOfTheExpression() {
    let expression = RetrievalQuery(#"text:"tower" NEAR(a b, 2) ^start pre* AND NOT -x OR {a b}:c"#).matchExpression
    #expect(
      expression
        == #""text tower NEAR a b 2 start pre AND NOT x OR c" OR "text" OR "tower" OR "NEAR" OR "a" OR "b" OR "2" OR "start" OR "pre" OR "AND" OR "NOT" OR "x" OR "OR" OR "c""#
    )
  }

  @Test func shouldKeepLettersMarksAndNumbersOfEveryScriptInOneTerm() {
    #expect(RetrievalQuery("cafe\u{0301} 潮が満ちる İstanbul ½ 42").terms == ["cafe\u{0301}", "潮が満ちる", "İstanbul", "½", "42"])
  }

  @Test func shouldDropRepeatedTermsAndStopAtTheTermLimit() {
    #expect(RetrievalQuery("Tower tower TOWER bell").terms == ["Tower", "bell"])
    let many = (0..<200).map { "w\($0)" }.joined(separator: " ")
    #expect(RetrievalQuery(many).terms.count == RetrievalQuery.maximumTerms)
  }
}
