import ShadowCore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private func volume(_ key: String, _ ordinal: Int, _ state: VolumeState) -> VolumeOrdinalRow {
  VolumeOrdinalRow(volumeKey: key, ordinal: ordinal, state: state)
}

private func volumeRows(_ rows: [JSONValue]) throws -> [VolumeOrdinalRow] {
  let states: [VolumeState?] = [.notStarted, .active, .goalMet]
  return try rows.compactMap { row in
    let index = try row.at(2).int()
    guard index >= 0, let state = states[index] else { return nil }
    return volume(try row.at(0).string(), try row.at(1).int(), state)
  }
}

struct VolumeStatsParityTests {
  @Test func shouldMatchTheReferenceVolumeStatsOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("volume", "stats")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let rows = try row.at(0).list().map { VolumeChapterRow(number: try $0.at(0).int(), wordCount: try $0.at(1).optionalInt()) }
      let expected = try row.at(1)
      let stats = VolumeStats(
        chapterCount: try expected.at(0).int(), firstChapter: try expected.at(1).optionalInt(), lastChapter: try expected.at(2).optionalInt(), wordCount: try expected.at(3).int())
      return deriveVolumeStats(rows) == stats
    }
    #expect(failed.isEmpty, "stats differ for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferencePlanRangeOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("volume", "planRange")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let expected = try row.at(1)
      let range = VolumePlanRange(planChapterCount: try expected.at(0).int(), planFirstChapter: try expected.at(1).optionalInt(), planLastChapter: try expected.at(2).optionalInt())
      return deriveVolumePlanRange(try row.at(0).ints()) == range
    }
    #expect(failed.isEmpty, "plan range differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceNextVolumeToActivateOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("volume", "next")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      nextVolumeToActivate(try volumeRows(try row.at(0).list()), volumeKey: try row.at(1).string()) == (try row.at(2).optionalString())
    }
    #expect(failed.isEmpty, "next volume differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceAutoActivationOnEveryFixtureCaseIgnoringRowsWithAnUnknownState() throws {
    let cases = try RuleFixture.section("volume", "autoActivate")
    #expect(cases.count >= 300)
    #expect(try cases.contains { try $0.at(0).list().contains { try $0.at(2).int() < 0 } })
    let failed = try mismatches(cases) { row in
      volumeToAutoActivate(try volumeRows(try row.at(0).list())) == (try row.at(1).optionalString())
    }
    #expect(failed.isEmpty, "auto activation differs for cases \(failed.prefix(10)) of \(failed.count)")
  }
}

struct VolumeStatsSpecTests {
  @Test func shouldReportZeroCountsForAVolumeWithNoChapters() {
    #expect(deriveVolumeStats([]) == emptyVolumeStats)
  }

  @Test func shouldComputeTheChapterCountRangeAndTotalWordCount() {
    let stats = deriveVolumeStats([VolumeChapterRow(number: 4, wordCount: 1200), VolumeChapterRow(number: 2, wordCount: 900), VolumeChapterRow(number: 3, wordCount: nil)])
    #expect(stats == VolumeStats(chapterCount: 3, firstChapter: 2, lastChapter: 4, wordCount: 2100))
  }

  @Test func shouldTreatASingleChapterAsItsOwnRange() {
    #expect(deriveVolumeStats([VolumeChapterRow(number: 7, wordCount: 500)]) == VolumeStats(chapterCount: 1, firstChapter: 7, lastChapter: 7, wordCount: 500))
  }

  @Test func shouldReportANullRangeForAVolumeWithNoChaptersAnywhereInThePlan() {
    #expect(deriveVolumePlanRange([]) == emptyVolumePlanRange)
  }

  @Test func shouldWidenTheRangeWithChapterNumbersAFinalOnlyRangeWouldMiss() {
    #expect(deriveVolumePlanRange([5, 2, 3]) == VolumePlanRange(planChapterCount: 3, planFirstChapter: 2, planLastChapter: 5))
  }

  @Test func shouldPickTheNearestNotStartedVolumeAfterTheGivenOne() {
    let volumes = [volume("v1", 1, .goalMet), volume("v2", 2, .active), volume("v3", 3, .notStarted), volume("v4", 4, .notStarted)]
    #expect(nextVolumeToActivate(volumes, volumeKey: "v2") == "v3")
    #expect(nextVolumeToActivate(volumes, volumeKey: "v3") == "v4")
    #expect(nextVolumeToActivate(volumes, volumeKey: "v4") == nil)
  }

  @Test func shouldReturnNoNextVolumeForAnUnknownVolume() {
    #expect(nextVolumeToActivate([volume("v1", 1, .active)], volumeKey: "missing") == nil)
  }

  @Test func shouldSkipALaterVolumeAlreadyActiveOrGoalMetInFavourOfTheNextNotStartedOne() {
    #expect(nextVolumeToActivate([volume("v1", 1, .active), volume("v2", 2, .goalMet), volume("v3", 3, .notStarted)], volumeKey: "v1") == "v3")
  }

  @Test func shouldActivateAProjectsFirstVolume() {
    #expect(volumeToAutoActivate([volume("v1", 1, .notStarted)]) == "v1")
  }

  @Test func shouldDoNothingWhileAVolumeIsAlreadyActive() {
    #expect(volumeToAutoActivate([volume("v1", 1, .active), volume("v2", 2, .notStarted)]) == nil)
  }

  @Test func shouldActivateANewlyInsertedVolumeOnceEveryEarlierOneIsGoalMet() {
    #expect(volumeToAutoActivate([volume("v1", 1, .goalMet), volume("v2", 2, .goalMet), volume("v3", 3, .notStarted)]) == "v3")
  }

  @Test func shouldNotActivateANotStartedVolumeAGoalMetOneHasAlreadyPassed() {
    #expect(volumeToAutoActivate([volume("v1", 1, .notStarted), volume("v2", 2, .goalMet)]) == nil)
  }

  @Test func shouldPickTheLowestOrdinalEligibleVolumeNotMerelyTheFirstInTheList() {
    #expect(volumeToAutoActivate([volume("v3", 3, .notStarted), volume("v2", 2, .notStarted)]) == "v2")
  }

  @Test func shouldNotActivateANotStartedVolumeSharingTheOrdinalOfAGoalMetOne() {
    #expect(volumeToAutoActivate([volume("a", 2, .goalMet), volume("b", 2, .notStarted)]) == nil)
  }

  @Test func shouldPickTheFirstListedVolumeWhenOrdinalsTie() {
    #expect(volumeToAutoActivate([volume("b", 2, .notStarted), volume("a", 2, .notStarted)]) == "b")
  }

  @Test func shouldNotCrashOnExtremeOrdinalsAndWordCounts() {
    #expect(volumeToAutoActivate([volume("a", Int.min, .notStarted), volume("b", Int.max, .goalMet)]) == nil)
    #expect(deriveVolumeStats([VolumeChapterRow(number: 1, wordCount: Int.max), VolumeChapterRow(number: 2, wordCount: 5)]).wordCount == Int.max)
  }
}

struct VolumeStatsPropertyTests {
  @Test func shouldKeepTheStatsRangeInsideTheChapterNumbers() throws {
    try forAll(iterations: 300) { generator in
      let numbers = (0..<generator.int(in: 0...8)).map { _ in generator.int(in: -5...50) }
      let range = deriveVolumePlanRange(numbers)
      #expect(range.planChapterCount == numbers.count)
      #expect(range.planFirstChapter == numbers.min() && range.planLastChapter == numbers.max())
    }
  }
}
