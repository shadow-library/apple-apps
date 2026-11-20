import ShadowText
import Testing

@testable import NovelForgeCore

private let teaches = learning("lamp_rank_4_rule")

private func refusal(briefs: [TeachingBrief], drafts: [TeachingDraft] = [], chapters: [TeachingChapter] = [], before chapter: Int = 6) -> TeachingGateError? {
  do throws(TeachingGateError) {
    try assertTeacherSettled(briefs: briefs, drafts: drafts, chapters: chapters, before: chapter)
    return nil
  } catch {
    return error
  }
}

struct AssertTeacherSettledSpecTests {
  @Test func shouldRefuseAnAIDraftOfTheNextChapterWhileAChapterThatTeachesSomethingAwaitsApproval() {
    let error = refusal(
      briefs: [TeachingBrief(chapter: 5, knowledgeContract: teaches), TeachingBrief(chapter: 6, knowledgeContract: .null)],
      drafts: [TeachingDraft(chapter: 5, status: .draft, reviewStatus: .needsReview)]
    )

    #expect(error == .teacherUnsettled(chapter: 6, teacher: 5))
    #expect(error?.code == "DRF_016")
  }

  @Test func shouldKeepRefusingPastAHandWrittenChapterWhileAnEarlierLessonIsStillUnapproved() {
    let error = refusal(
      briefs: [TeachingBrief(chapter: 4, knowledgeContract: teaches), TeachingBrief(chapter: 5, knowledgeContract: .null)],
      drafts: [TeachingDraft(chapter: 4, status: .draft, reviewStatus: .needsReview), TeachingDraft(chapter: 5, status: .draft, reviewStatus: .needsReview)]
    )

    #expect(error?.errorDescription?.contains("until chapter 4 is approved") == true)
  }

  @Test(
    arguments: [
      ("approved", TeachingDraft(chapter: 5, status: .draft, reviewStatus: .approved), false),
      ("final", TeachingDraft(chapter: 5, status: .final, reviewStatus: .final), false),
      ("finalized without a draft", nil, true),
    ] as [(String, TeachingDraft?, Bool)])
  func shouldLetTheNextChapterThroughWhenThePreviousOneIs(_ label: String, _ draft: TeachingDraft?, _ finalized: Bool) {
    let error = refusal(
      briefs: [TeachingBrief(chapter: 5, knowledgeContract: teaches)],
      drafts: draft.map { [$0] } ?? [],
      chapters: finalized ? [TeachingChapter(number: 5, status: .done)] : []
    )

    #expect(error == nil, "\(label)")
  }

  @Test func shouldLetTheNextChapterThroughWhenThePreviousOneTeachesNothing() {
    let empty = object(("pov", .array([.string("mira")])), ("learns", .array([])))

    #expect(refusal(briefs: [TeachingBrief(chapter: 5, knowledgeContract: empty)], drafts: [TeachingDraft(chapter: 5, status: .draft, reviewStatus: .needsReview)]) == nil)
  }

  @Test func shouldWordTheRefusalAsTheReferenceCatalogDoes() {
    let error = TeachingGateError.teacherUnsettled(chapter: 6, teacher: 4)

    #expect(
      error.errorDescription
        == "Chapter 6 cannot be written by the AI until chapter 4 is approved — its characters learn something there that later chapters build on. You can still write chapter 6 yourself."
    )
  }
}

struct UntilFirstTeacherSpecTests {
  @Test func shouldEndABatchAtTheFirstChapterWhosePlanTeachesSomething() {
    let plans: [Int: OrderedJSON] = [4: .null, 5: teaches, 6: .null]

    #expect(untilFirstTeacher([4, 5, 6], plans: plans) == [4, 5])
    #expect(untilFirstTeacher([6], plans: plans) == [6])
  }
}
