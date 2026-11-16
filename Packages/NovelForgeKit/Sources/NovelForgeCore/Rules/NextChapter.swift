import ShadowCore

enum NextChapterError: ShadowError, Equatable {
  case notNextChapter(chapter: Int, next: Int)

  var code: String { "DRF_018" }

  var errorDescription: String? {
    switch self {
    case .notNextChapter(let chapter, let next):
      "Only chapter \(next) can be started now — chapters are written in order, so chapter \(chapter) cannot get a new draft"
    }
  }
}

// apps/novel-forge-server/src/common/next-chapter.ts:11
func nextWritableChapter(draftChapters: [Int], finalizedChapters: [Int]) -> Int {
  firstUnwrittenChapter(started: Set(draftChapters), finalized: Set(finalizedChapters))
}

// apps/novel-forge-server/src/common/next-chapter.ts:18
func assertStartsNextChapter(_ chapter: Int, draftChapters: [Int], finalizedChapters: [Int]) throws(NextChapterError) {
  let next = nextWritableChapter(draftChapters: draftChapters, finalizedChapters: finalizedChapters)
  if chapter != next { throw .notNextChapter(chapter: chapter, next: next) }
}
