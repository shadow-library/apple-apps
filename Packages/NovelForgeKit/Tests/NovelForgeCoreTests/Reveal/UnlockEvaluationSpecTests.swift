import Testing

@testable import NovelForgeCore

private let volumes: [JSString: Int] = ["the_marsh": 1, "the_tower": 2, "the_sea": 3]

private func at(
  chapter: Int = 10,
  endingChapter: Int? = nil,
  volumeKey: String? = "the_tower",
  reached: [String] = []
) -> UnlockContext {
  UnlockContext(chapter: chapter, endingChapter: endingChapter, volumeKey: volumeKey, volumeOrdinals: volumes, reachedMilestones: keys(reached))
}

private func holds(_ term: UnlockTerm, _ context: UnlockContext) -> Bool {
  evaluateUnlock(UnlockCondition(all: [term]), context).holds
}

struct EvaluateUnlockSpecTests {
  @Test func shouldHoldAMilestoneTermOnlyWhenThatMilestoneCountsAsReached() {
    #expect(holds(.milestone("lamp_rank_4"), at(reached: ["lamp_rank_4"])))
    #expect(!holds(.milestone("lamp_rank_4"), at()))
  }

  @Test func shouldNeverLetALaterRankStandInForAnEarlierOne() {
    let context = at(reached: ["lamp_rank_5"])

    #expect(!holds(.milestone("lamp_rank_4"), context))
    #expect(holds(.milestone("lamp_rank_5"), context))
  }

  @Test func shouldHoldAChapterTermFromThatChapterOn() {
    #expect(holds(.chapter(10), at()))
    #expect(holds(.chapter(9), at()))
    #expect(!holds(.chapter(11), at()))
  }

  @Test func shouldHoldAVolumeTermOnceThePlanIsInThatVolumeOrALaterOneByOrdinal() {
    #expect(holds(.volume("the_marsh"), at()))
    #expect(holds(.volume("the_tower"), at()))
    #expect(!holds(.volume("the_sea"), at()))
  }

  @Test func shouldNotHoldAVolumeTermForAPlanOutsideEveryVolumeOrAVolumeTheNovelDoesNotHave() {
    #expect(!holds(.volume("the_marsh"), at(volumeKey: nil)))
    #expect(!holds(.volume("the_marsh"), at(volumeKey: "the_lost_volume")))
    #expect(!holds(.volume("the_lost_volume"), at()))
  }

  @Test func shouldHoldTheEndingTermFromTheChapterPlannedAsTheEndingOnSoAnEpilogueMayRevealItToo() {
    #expect(holds(.ending, at(endingChapter: 10)))
    #expect(holds(.ending, at(endingChapter: 8)))
    #expect(!holds(.ending, at(endingChapter: 11)))
    #expect(!holds(.ending, at(chapter: 500)))
  }

  @Test func shouldHoldAConjunctionOnlyWhenEveryTermHoldsAndListEachMissingTerm() {
    let all: [UnlockTerm] = [.milestone("lamp_rank_4"), .volume("the_sea"), .chapter(12), .ending]
    let table: [(UnlockContext, [UnlockTerm])] = [
      (at(), all),
      (at(reached: ["lamp_rank_4"]), [.volume("the_sea"), .chapter(12), .ending]),
      (at(chapter: 12, volumeKey: "the_sea", reached: ["lamp_rank_4"]), [.ending]),
      (at(chapter: 12, endingChapter: 12, volumeKey: "the_sea", reached: ["lamp_rank_4"]), []),
      (at(chapter: 12, endingChapter: 12, volumeKey: "the_sea"), [.milestone("lamp_rank_4")]),
    ]

    for (context, missing) in table {
      #expect(evaluateUnlock(UnlockCondition(all: all), context) == UnlockEvaluation(holds: missing.isEmpty, missing: missing))
    }
  }
}

struct DescribeUnlockTermSpecTests {
  @Test func shouldNameEachKindOfTermForAnErrorMessage() {
    let terms: [UnlockTerm] = [.milestone("lamp_rank_4"), .volume("the_sea"), .chapter(12), .ending]

    #expect(terms.map(describeUnlockTerm) == ["milestone lamp_rank_4 reached", "volume the_sea reached", "chapter 12 or later", "the planned ending or later"])
  }
}
