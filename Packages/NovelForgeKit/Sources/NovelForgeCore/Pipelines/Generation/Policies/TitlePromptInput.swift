struct TitleReferenceChapter: Equatable, Sendable {
  let number: Int
  let title: String?
  let isolated: Bool
  let isDone: Bool
}

struct TitlePromptInput: Equatable, Sendable {
  let existingTitles: String
  let chapterSummary: String
}

enum TitlePromptInputs {
  static let existingTitlesMax = 10
  static let noTitlesYet = "(none yet)"

  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:311
  static func make<Scrubber: WriterTextScrubbing>(
    chapter: Int, summary: String, chapters: [TitleReferenceChapter], scrubber: inout Scrubber
  ) throws(DisclosureError) -> TitlePromptInput {
    let earlier = chapters.filter { $0.isDone && $0.number < chapter }.sorted { $0.number > $1.number }.prefix(existingTitlesMax)
    var titles: [String] = []
    for row in earlier.reversed() where !row.isolated && !(row.title?.jsTrim().isEmpty ?? true) {
      titles.append("- Ch \(row.number): \(try scrubber.scrub(row.title ?? "", .heading))")
    }
    let chapterSummary = try scrubber.scrub(summary, .summary)
    return TitlePromptInput(existingTitles: titles.isEmpty ? noTitlesYet : titles.joined(separator: "\n"), chapterSummary: chapterSummary)
  }
}
