import Testing

@testable import NovelForgeCore

struct WriterFacingParityTests {
  private struct FacingCase: Decodable {
    let findings: [FindingFixture]
    let knowledgeWriterFindings: [FindingFixture]
    let rendered: String
    let calls: [String]
  }

  private struct ChapterFixture: Decodable {
    let number: Int
    let title: String?
    let isolated: Bool
    let status: String

    var chapter: TitleReferenceChapter { TitleReferenceChapter(number: number, title: title, isolated: isolated, isDone: status == "done") }
  }

  private struct TitleResult: Decodable {
    let existingTitles: String
    let chapterSummary: String
  }

  private struct TitleCase: Decodable {
    let chapter: Int
    let summary: String
    let chapters: [ChapterFixture]
    let result: TitleResult
    let calls: [String]
    let limit: Int
  }

  @Test func shouldMatchTheReferenceWriterFacingFindings() throws {
    let cases: [FacingCase] = try GenerationFixtures.load("writer-facing")
    #expect(cases.count > 7)
    for (index, row) in cases.enumerated() {
      var scrubber = RecordingScrubber()
      let rendered = try WriterFacingFindings.render(findings: row.findings.findings, knowledgeWriterFindings: row.knowledgeWriterFindings.findings, scrubber: &scrubber)
      #expect(rendered == row.rendered, "case \(index)")
      #expect(scrubber.calls == row.calls, "scrub calls of case \(index)")
    }
  }

  @Test func shouldMatchTheReferenceTitlePromptInput() throws {
    let cases: [TitleCase] = try GenerationFixtures.load("titles")
    #expect(cases.count > 40)
    #expect(Set(cases.map(\.limit)) == [TitlePromptInputs.existingTitlesMax])
    var empty = 0
    for (index, row) in cases.enumerated() {
      var scrubber = RecordingScrubber()
      let input = try TitlePromptInputs.make(chapter: row.chapter, summary: row.summary, chapters: row.chapters.map(\.chapter), scrubber: &scrubber)
      #expect(input == TitlePromptInput(existingTitles: row.result.existingTitles, chapterSummary: row.result.chapterSummary), "case \(index)")
      #expect(scrubber.calls == row.calls, "scrub calls of case \(index)")
      if input.existingTitles == TitlePromptInputs.noTitlesYet { empty += 1 }
    }
    #expect(empty > 3 && empty < cases.count)
  }
}
