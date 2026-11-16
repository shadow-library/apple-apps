struct BatchBrief: Equatable, Sendable {
  var chapter: Int
  var writeMode: BriefWriteMode
}

enum GenerationBatchStop: Equatable, Sendable {
  case externalChapter(Int)
  case unwrittenChapter(Int, blocking: Int)
}

struct GenerationBatch: Equatable, Sendable {
  var chapters: [Int]
  var stop: GenerationBatchStop?

  init(chapters: [Int], stop: GenerationBatchStop? = nil) {
    self.chapters = chapters
    self.stop = stop
  }
}

// apps/novel-forge-server/src/common/batch-selection.ts:19
func firstUnwrittenChapter(started: Set<Int>, finalized: Set<Int>) -> Int {
  var chapter = 1
  while chapter < Int.max, started.contains(chapter) || finalized.contains(chapter) { chapter += 1 }
  return chapter
}

// apps/novel-forge-server/src/common/batch-selection.ts:31
func selectGenerationBatch(_ briefs: [BatchBrief], started: Set<Int>, finalized: Set<Int>, limit: Int) -> GenerationBatch {
  func written(_ chapter: Int) -> Bool { started.contains(chapter) || finalized.contains(chapter) }
  var frontier = 0
  func advance() {
    while frontier < Int.max, written(frontier + 1) { frontier += 1 }
  }
  advance()

  var chapters: [Int] = []
  for brief in briefs.jsStableSorted(by: { $0.chapter < $1.chapter }) {
    if chapters.count >= limit { return GenerationBatch(chapters: chapters) }
    if brief.writeMode == .external, !written(brief.chapter) { return GenerationBatch(chapters: chapters, stop: .externalChapter(brief.chapter)) }
    if written(brief.chapter) { continue }
    if frontier < Int.max, frontier + 1 < brief.chapter { return GenerationBatch(chapters: chapters, stop: .unwrittenChapter(frontier + 1, blocking: brief.chapter)) }
    chapters.append(brief.chapter)
    frontier = brief.chapter
    advance()
  }
  return GenerationBatch(chapters: chapters)
}
