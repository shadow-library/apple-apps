import ShadowCore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private func standard(_ chapter: Int) -> BatchBrief { BatchBrief(chapter: chapter, writeMode: .standard) }
private func external(_ chapter: Int) -> BatchBrief { BatchBrief(chapter: chapter, writeMode: .external) }

private func select(_ briefs: [BatchBrief], started: Set<Int> = [], finalized: Set<Int> = [], limit: Int) -> GenerationBatch {
  selectGenerationBatch(briefs, started: started, finalized: finalized, limit: limit)
}

struct BatchSelectionParityTests {
  @Test func shouldMatchTheReferenceSelectionOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("batch", "select")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let modes: [BriefWriteMode] = [.standard, .external, .standard]
      let briefs = try row.at(0).list().map { BatchBrief(chapter: try $0.at(0).int(), writeMode: modes[try $0.at(1).int()]) }
      let result = select(briefs, started: Set(try row.at(1).ints()), finalized: Set(try row.at(2).ints()), limit: try row.at(3).int())
      let expected = try row.at(4)
      let stop: GenerationBatchStop? =
        if let external = try expected.at(1).optionalInt() {
          .externalChapter(external)
        } else if let unwritten = try expected.at(2).optionalInt(), let blocked = try expected.at(3).optionalInt() {
          .unwrittenChapter(unwritten, blocking: blocked)
        } else {
          nil
        }
      return result == GenerationBatch(chapters: try expected.at(0).ints(), stop: stop)
    }
    #expect(failed.isEmpty, "selection differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceFirstUnwrittenChapterOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("batch", "firstUnwritten")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) {
      firstUnwrittenChapter(started: Set(try $0.at(0).ints()), finalized: Set(try $0.at(1).ints())) == (try $0.at(2).int())
    }
    #expect(failed.isEmpty, "first unwritten chapter differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceNextWritableChapterAndRefusalOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("batch", "nextChapter")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let drafts = try row.at(0).ints()
      let finals = try row.at(1).ints()
      let chapter = try row.at(2).int()
      let next = try row.at(3).int()
      let refused = try row.at(4).int() == 1
      guard nextWritableChapter(draftChapters: drafts, finalizedChapters: finals) == next else { return false }
      do {
        try assertStartsNextChapter(chapter, draftChapters: drafts, finalizedChapters: finals)
        return !refused
      } catch let error as NextChapterError {
        return refused && error == .notNextChapter(chapter: chapter, next: next)
      } catch {
        return false
      }
    }
    #expect(failed.isEmpty, "next chapter differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldWordTheNextChapterRefusalAsTheReferenceDoes() throws {
    let messages = try RuleFixture.section("batch", "nextChapterMessages")
    #expect(!messages.isEmpty)
    for row in messages {
      let error = NextChapterError.notNextChapter(chapter: try row.at(0).int(), next: try row.at(1).int())
      #expect(error.errorDescription == (try row.at(2).string()))
      #expect(error.code == "DRF_018")
    }
  }
}

struct BatchSelectionSpecTests {
  @Test func shouldTakeTheNextUndraftedChaptersInAscendingOrderWhenNoSlotIsExternal() {
    let briefs = [standard(1), standard(2), standard(3), standard(4)]
    #expect(select(briefs, started: [1], finalized: [1], limit: 20) == GenerationBatch(chapters: [2, 3, 4]))
  }

  @Test func shouldOrderTheBatchEvenWhenTheBriefsArriveUnsorted() {
    #expect(select([standard(3), standard(1), standard(2)], limit: 2) == GenerationBatch(chapters: [1, 2]))
  }

  @Test func shouldStopAtAnExternalSlotInsteadOfSkippingPastIt() {
    let briefs = [standard(1), standard(2), standard(3), external(4), standard(5), standard(6)]
    #expect(select(briefs, limit: 20) == GenerationBatch(chapters: [1, 2, 3], stop: .externalChapter(4)))
  }

  @Test func shouldStopBeforeAnExternalSlotThatIsTheImmediateNextChapter() {
    #expect(select([external(1), standard(2)], limit: 5) == GenerationBatch(chapters: [], stop: .externalChapter(1)))
  }

  @Test func shouldStopAtTheFirstOfSeveralConsecutiveExternalSlots() {
    let briefs = [standard(1), external(2), external(3), external(4), standard(5)]
    #expect(select(briefs, limit: 5) == GenerationBatch(chapters: [1], stop: .externalChapter(2)))
  }

  @Test func shouldResumePastAnExternalSlotWhoseChapterIsFinalized() {
    let briefs = [standard(1), external(2), standard(3), standard(4)]
    #expect(select(briefs, started: [1, 2], finalized: [1, 2], limit: 20) == GenerationBatch(chapters: [3, 4]))
  }

  @Test func shouldCarryOnPastAnExternalSlotTheAuthorHasWrittenByHandBeforeItIsFinalized() {
    let briefs = [standard(1), external(2), standard(3)]
    #expect(select(briefs, started: [1, 2], finalized: [1], limit: 20) == GenerationBatch(chapters: [3]))
  }

  @Test func shouldReportNoStopWhenTheLimitIsReachedBeforeTheExternalSlot() {
    #expect(select([standard(1), standard(2), external(3)], limit: 2) == GenerationBatch(chapters: [1, 2]))
  }

  @Test func shouldReturnAnEmptyBatchForAProjectWithNoBriefs() {
    #expect(select([], limit: 20) == GenerationBatch(chapters: []))
  }

  @Test func shouldRefuseToSkipAheadToAPlannedChapterOverChaptersWithNeitherAPlanNorProse() {
    let result = select([standard(1), standard(2), standard(3), standard(12)], started: [1, 2, 3], finalized: [1, 2, 3], limit: 5)
    #expect(result == GenerationBatch(chapters: [], stop: .unwrittenChapter(4, blocking: 12)))
  }

  @Test func shouldTruncateABatchAtTheGapAfterTheChaptersItCanReach() {
    #expect(select([standard(1), standard(2), standard(5)], limit: 5) == GenerationBatch(chapters: [1, 2], stop: .unwrittenChapter(3, blocking: 5)))
  }

  @Test func shouldStopAtAHoleFurtherBackThanTheChapterBeforeSuchAsEmptyChaptersAheadOfAnImportedDraft() {
    let result = select([standard(11)], started: [1, 2, 3, 10], finalized: [1, 2, 3], limit: 5)
    #expect(result == GenerationBatch(chapters: [], stop: .unwrittenChapter(4, blocking: 11)))
  }

  @Test func shouldFillTheHoleInOrderAndCarryOnPastADraftThatAlreadySitsBeyondIt() {
    let briefs = [4, 5, 6, 7, 8, 9, 11].map(standard)
    #expect(select(briefs, started: [1, 2, 3, 10], finalized: [1, 2, 3], limit: 10) == GenerationBatch(chapters: [4, 5, 6, 7, 8, 9, 11]))
  }

  @Test func shouldContinueAnImportedNovelWhoseFinalizedChaptersCarryNoPlans() {
    #expect(select([standard(41), standard(42)], finalized: Set(1...40), limit: 5) == GenerationBatch(chapters: [41, 42]))
  }

  @Test func shouldNeverGenerateAFinalizedChapterThatHasNoDraft() {
    #expect(select([standard(1), standard(2)], finalized: [1], limit: 5) == GenerationBatch(chapters: [2]))
  }

  @Test func shouldAnswerTheLowestChapterWithNeitherADraftNorFinalizedProse() {
    #expect(firstUnwrittenChapter(started: [1, 2, 5], finalized: [3]) == 4)
    #expect(firstUnwrittenChapter(started: [], finalized: []) == 1)
  }

  @Test func shouldRefuseANewDraftAwayFromTheNextWritableChapter() throws {
    try assertStartsNextChapter(3, draftChapters: [1, 2], finalizedChapters: [])
    #expect(throws: NextChapterError.notNextChapter(chapter: 5, next: 3)) {
      try assertStartsNextChapter(5, draftChapters: [1, 2], finalizedChapters: [])
    }
  }
}

struct BatchSelectionPropertyTests {
  @Test func shouldReturnChaptersInAscendingOrderWithinTheLimitAndNeverAWrittenOne() throws {
    try forAll(iterations: 500) { generator in
      let started = Set((0..<generator.int(in: 0...6)).map { _ in generator.int(in: -2...12) })
      let finalized = Set((0..<generator.int(in: 0...6)).map { _ in generator.int(in: -2...12) })
      let briefs = (0..<generator.int(in: 0...8)).map { _ in BatchBrief(chapter: generator.int(in: 1...14), writeMode: generator.chance(0.3) ? .external : .standard) }
      let limit = generator.int(in: 0...10)
      let result = select(briefs, started: started, finalized: finalized, limit: limit)
      let distinct = Set(briefs.map(\.chapter))
      guard distinct.count == briefs.count else { return }
      #expect(result.chapters == result.chapters.sorted())
      #expect(result.chapters.count <= limit)
      #expect(result.chapters.allSatisfy { !started.contains($0) && !finalized.contains($0) })
    }
  }

  @Test func shouldYieldAFirstUnwrittenChapterThatIsNeitherDraftedNorFinalized() throws {
    try forAll(iterations: 300) { generator in
      let started = Set((0..<generator.int(in: 0...10)).map { _ in generator.int(in: 1...12) })
      let finalized = Set((0..<generator.int(in: 0...10)).map { _ in generator.int(in: 1...12) })
      let chapter = firstUnwrittenChapter(started: started, finalized: finalized)
      #expect(!started.contains(chapter) && !finalized.contains(chapter))
      #expect((1..<chapter).allSatisfy { started.contains($0) || finalized.contains($0) })
    }
  }
}
