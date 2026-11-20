import ShadowCore
import ShadowText

enum DraftStatus: String, Sendable {
  case draft
  case final
}

enum DraftReviewStatus: String, Sendable {
  case generating
  case needsReview = "needs_review"
  case contradiction
  case approved
  case final
}

enum ChapterStatus: String, Sendable {
  case done
  case failed
  case skipped
}

struct TeachingBrief: Equatable, Sendable {
  var chapter: Int
  var knowledgeContract: OrderedJSON
}

struct TeachingDraft: Equatable, Sendable {
  var chapter: Int
  var status: DraftStatus
  var reviewStatus: DraftReviewStatus
}

struct TeachingChapter: Equatable, Sendable {
  var number: Int
  var status: ChapterStatus
}

enum TeachingGateError: ShadowError, Equatable {
  case teacherUnsettled(chapter: Int, teacher: Int)

  var code: String { "DRF_016" }

  var errorDescription: String? {
    switch self {
    case .teacherUnsettled(let chapter, let teacher):
      let (at, teacher) = (Double(chapter).jsString, Double(teacher).jsString)
      return
        "Chapter \(at) cannot be written by the AI until chapter \(teacher) is approved — its characters learn something there that later chapters build on. You can still write chapter \(at) yourself."
    }
  }
}

private func teaches(_ knowledgeContract: OrderedJSON) -> Bool {
  !(parseKnowledgeContract(knowledgeContract)?.learns.isEmpty ?? true)
}

// platform/apps/novel-forge-server/src/common/teaching-gate.ts:14
func unsettledTeacher(briefs: [TeachingBrief], drafts: [TeachingDraft], chapters: [TeachingChapter], before chapter: Int) -> Int? {
  let finalized = chapters.filter { $0.status == .done && $0.number < chapter }.map(\.number)
  let approved = drafts.filter { $0.chapter < chapter && ($0.status == .final || $0.reviewStatus == .approved) }.map(\.chapter)
  let settled = Set(finalized + approved)
  return briefs.filter { $0.chapter < chapter && teaches($0.knowledgeContract) && !settled.contains($0.chapter) }.map(\.chapter).min()
}

// platform/apps/novel-forge-server/src/common/teaching-gate.ts:36
func untilFirstTeacher(_ chapters: [Int], plans: [Int: OrderedJSON]) -> [Int] {
  guard let teacher = chapters.firstIndex(where: { chapter in plans[chapter].map(teaches) ?? false }) else { return chapters }
  return Array(chapters[...teacher])
}

// platform/apps/novel-forge-server/src/common/teaching-gate.ts:42
func assertTeacherSettled(briefs: [TeachingBrief], drafts: [TeachingDraft], chapters: [TeachingChapter], before chapter: Int) throws(TeachingGateError) {
  guard let teacher = unsettledTeacher(briefs: briefs, drafts: drafts, chapters: chapters, before: chapter) else { return }
  throw .teacherUnsettled(chapter: chapter, teacher: teacher)
}
