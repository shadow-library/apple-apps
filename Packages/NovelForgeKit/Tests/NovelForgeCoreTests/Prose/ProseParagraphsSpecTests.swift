import Testing

@testable import NovelForgeCore

struct ProseParagraphsSpecTests {
  private func spans(_ text: String) -> [[Int]] {
    proseParagraphs(text).map { [$0.start, $0.end] }
  }

  @Test func shouldBuildTheSharedScanner() {
    #expect(ProseScanner.shared != nil)
  }

  @Test func shouldReturnNoBlocksForBlankText() {
    #expect(spans("") == [])
    #expect(spans(" \n\t\r\n  ") == [])
  }

  @Test func shouldSplitParagraphsOnBlankLinesOfEveryLineEnding() {
    #expect(spans("one\ntwo\n\nthree") == [[0, 7], [9, 14]])
    #expect(spans("one\r\ntwo\r\n\r\nthree") == [[0, 8], [12, 17]])
    #expect(spans("one\r\rtwo") == [[0, 3], [5, 8]])
  }

  @Test func shouldNotCountASceneBreakAsABlock() {
    #expect(spans("a\n\n***\n\nb") == [[0, 1], [8, 9]])
  }

  @Test func shouldCountOffsetsInUTF16CodeUnits() {
    #expect(spans("😀 a\n\nb") == [[0, 4], [6, 7]])
  }

  @Test func shouldTrimOnlyWhatTheReferenceTrims() {
    #expect(spans("  a  \n\n\u{00A0}") == [[2, 3], [8, 7]])
  }

  @Test func shouldKeepAFencedBlockWhole() {
    #expect(spans("```\ncode\n\nmore\n```\nafter") == [[0, 18], [19, 24]])
    #expect(spans("```\nunterminated\n\nrest") == [[0, 22]])
    #expect(spans("~~~\na\n~~~~\nb") == [[0, 10], [11, 12]])
  }

  @Test func shouldKeepATableWholeAndStopItAtABlockStart() {
    #expect(spans("| a | b |\n|---|---|\n| 1 | 2 |\n\nnext") == [[0, 29], [31, 35]])
    #expect(spans("| a | b |\n|---|---|\n- item") == [[0, 19], [20, 26]])
  }

  @Test func shouldTreatAnEscapedPipeAsPartOfACell() {
    #expect(spans("| a \\| b |\n|---|\n| 1 |") == [[0, 22]])
  }

  @Test func shouldRunAListThroughBlankLinesWhileItemsOrIndentFollow() {
    #expect(spans("- a\n\n- b\n\n  c\n\nafter") == [[0, 13], [15, 20]])
  }

  @Test func shouldEndAParagraphAtASetextUnderline() {
    #expect(spans("text\n===\nmore") == [[0, 8], [9, 13]])
  }

  @Test func shouldNumberOffsetsBetweenBlocksAsTheNextAndPastTheEndAsTheLast() {
    let paragraphs = proseParagraphs("ab\n\ncd")
    #expect(paragraphNumberAt(paragraphs, offset: 0) == 1)
    #expect(paragraphNumberAt(paragraphs, offset: 2) == 2)
    #expect(paragraphNumberAt(paragraphs, offset: 3) == 2)
    #expect(paragraphNumberAt(paragraphs, offset: 99) == 2)
    #expect(paragraphNumberAt(paragraphs, offset: -4) == 1)
    #expect(paragraphNumberAt([], offset: 3) == 1)
    #expect(paragraphAt("", offset: 0) == 1)
  }
}
