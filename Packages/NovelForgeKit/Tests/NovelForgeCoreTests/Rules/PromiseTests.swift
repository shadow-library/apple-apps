import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

private let milestoneStates: [MilestoneState] = [.open, .planned, .reached]

private func milestoneMap(_ entries: [JSONValue]) throws -> [JSString: MilestoneState] {
  Dictionary(
    jsEntries: try entries.compactMap { entry -> (key: String, value: MilestoneState)? in
      let index = try entry.at(1).int()
      return index < 0 ? nil : (key: try entry.at(0).string(), value: milestoneStates[index])
    })
}

private func volumeMap(_ entries: [JSONValue]) throws -> [JSString: VolumeState] {
  Dictionary(
    jsEntries: try entries.compactMap { entry -> (key: String, value: VolumeState)? in
      let index = try entry.at(1).int()
      return index < 0 ? nil : (key: try entry.at(0).string(), value: VolumeState.allCases[index])
    })
}

private func payoff(window: Int? = nil, milestone: String? = nil, volume: String? = nil) -> PromisePayoff {
  PromisePayoff(payoffWindow: window, payoffMilestoneKey: milestone, payoffVolumeKey: volume)
}

private func thread(_ overrides: (inout ThreadRow) -> Void = { _ in }) -> ThreadRow {
  var row = ThreadRow(
    threadKey: "thread-1",
    summary: "A thread",
    status: .open,
    intentionallyOpen: false,
    openedChapter: 1,
    closedChapter: nil,
    lastAdvancedChapter: 3,
    payoff: payoff(),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2)
  )
  overrides(&row)
  return row
}

private func mystery(_ overrides: (inout MysteryRow) -> Void = { _ in }) -> MysteryRow {
  var row = MysteryRow(
    mysteryKey: "mystery-1",
    question: "Who did it?",
    status: .open,
    intentionallyOpen: false,
    openedChapter: 1,
    resolvedChapter: nil,
    lastAdvancedChapter: 3,
    payoff: payoff(),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2)
  )
  overrides(&row)
  return row
}

struct PromiseParityTests {
  @Test func shouldMatchTheReferenceDueStandingOnEveryFixtureCaseIgnoringStatesNoEnumHolds() throws {
    let cases = try RuleFixture.section("promise", "due")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let target = PromisePayoff(payoffWindow: try row.at(0).optionalInt(), payoffMilestoneKey: try row.at(1).optionalString(), payoffVolumeKey: try row.at(2).optionalString())
      let standing = resolvePromiseDueStanding(
        target, chapter: try row.at(3).int(), milestoneStates: try milestoneMap(try row.at(4).list()), volumeStates: try volumeMap(try row.at(5).list()))
      return standing.rawValue == (try row.at(6).string())
    }
    #expect(failed.isEmpty, "due standing differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  private func checkItems(_ name: String, make: (JSONValue, PromisePayoff, Date, Date) throws -> PromiseItem) throws {
    let cases = try RuleFixture.section("promise", name)
    #expect(cases.count >= 300)
    let failed = try cases.indices.filter { index in
      let row = try cases[index].at(0)
      let expected = try cases[index].at(1)
      let target = PromisePayoff(payoffWindow: try row.at(7).optionalInt(), payoffMilestoneKey: try row.at(8).optionalString(), payoffVolumeKey: try row.at(9).optionalString())
      let created = Date(timeIntervalSince1970: Double(index))
      let updated = Date(timeIntervalSince1970: Double(index + 1))
      let item = try make(row, target, created, updated)
      let key = try row.at(0).string()
      let intentionallyOpen = try row.at(3).bool()
      let opened = try row.at(4).optionalInt()
      let advanced = try row.at(5).optionalInt()
      let label = try expected.at(0).string()
      let due = try expected.at(1).string()
      let matches = item.label == label && item.due.rawValue == due && item.key == key && item.intentionallyOpen == intentionallyOpen
      return !(matches && item.openedChapter == opened && item.lastAdvancedChapter == advanced && item.payoff == target && item.createdAt == created && item.updatedAt == updated)
    }
    #expect(failed.isEmpty, "\(name) differ for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceThreadItemOnEveryFixtureCase() throws {
    let statuses: [ThreadStatus] = [.open, .closed, .dropped]
    try checkItems("threads") { row, target, created, updated in
      let status = statuses[try row.at(2).int()]
      let ended = try row.at(6).optionalInt()
      let item = threadPromiseItem(
        ThreadRow(
          threadKey: try row.at(0).string(),
          summary: try row.at(1).optionalString(),
          status: status,
          intentionallyOpen: try row.at(3).bool(),
          openedChapter: try row.at(4).optionalInt(),
          closedChapter: ended,
          lastAdvancedChapter: try row.at(5).optionalInt(),
          payoff: target,
          createdAt: created,
          updatedAt: updated
        ),
        chapter: try row.at(10).int(),
        milestoneStates: try milestoneMap(try row.at(11).list()),
        volumeStates: try volumeMap(try row.at(12).list())
      )
      #expect(item.kind == .thread && item.closedChapter == ended && item.resolvedChapter == nil && item.status == status.promiseStatus)
      return item
    }
  }

  @Test func shouldMatchTheReferenceMysteryItemOnEveryFixtureCase() throws {
    let statuses: [MysteryStatus] = [.open, .resolved, .dropped]
    try checkItems("mysteries") { row, target, created, updated in
      let status = statuses[try row.at(2).int()]
      let ended = try row.at(6).optionalInt()
      let item = mysteryPromiseItem(
        MysteryRow(
          mysteryKey: try row.at(0).string(),
          question: try row.at(1).string(),
          status: status,
          intentionallyOpen: try row.at(3).bool(),
          openedChapter: try row.at(4).optionalInt(),
          resolvedChapter: ended,
          lastAdvancedChapter: try row.at(5).optionalInt(),
          payoff: target,
          createdAt: created,
          updatedAt: updated
        ),
        chapter: try row.at(10).int(),
        milestoneStates: try milestoneMap(try row.at(11).list()),
        volumeStates: try volumeMap(try row.at(12).list())
      )
      #expect(item.kind == .mystery && item.resolvedChapter == ended && item.closedChapter == nil && item.status == status.promiseStatus)
      return item
    }
  }
}

struct PromiseSpecTests {
  @Test func shouldReportNotDueWhenNothingNamedAPayoffHasBeenReached() {
    #expect(resolvePromiseDueStanding(payoff(window: 10), chapter: 5) == .notDue)
  }

  @Test func shouldReportOverdueOnceTheAuthoredChapterWindowHasPassed() {
    #expect(resolvePromiseDueStanding(payoff(window: 10), chapter: 10) == .overdue)
    #expect(resolvePromiseDueStanding(payoff(window: 10), chapter: 11) == .overdue)
  }

  @Test func shouldReportDueOnceThePayoffMilestoneIsReached() {
    let states = Dictionary(jsEntries: [(key: "mk", value: MilestoneState.reached)])
    #expect(resolvePromiseDueStanding(payoff(milestone: "mk"), chapter: 1, milestoneStates: states) == .due)
  }

  @Test func shouldStayNotDueWhileThePayoffMilestoneHasNotBeenReached() {
    let states = Dictionary(jsEntries: [(key: "mk", value: MilestoneState.open)])
    #expect(resolvePromiseDueStanding(payoff(milestone: "mk"), chapter: 1, milestoneStates: states) == .notDue)
  }

  @Test func shouldReportDueWhileThePayoffVolumeIsTheOneNowActive() {
    let states = Dictionary(jsEntries: [(key: "vk", value: VolumeState.active)])
    #expect(resolvePromiseDueStanding(payoff(volume: "vk"), chapter: 1, volumeStates: states) == .due)
  }

  @Test func shouldReportOverdueOnceThePayoffVolumeHasAlreadyMetItsGoal() {
    let states = Dictionary(jsEntries: [(key: "vk", value: VolumeState.goalMet)])
    #expect(resolvePromiseDueStanding(payoff(volume: "vk"), chapter: 1, volumeStates: states) == .overdue)
  }

  @Test func shouldStayNotDueWhileThePayoffVolumeHasNotStarted() {
    let states = Dictionary(jsEntries: [(key: "vk", value: VolumeState.notStarted)])
    #expect(resolvePromiseDueStanding(payoff(volume: "vk"), chapter: 1, volumeStates: states) == .notDue)
  }

  @Test func shouldLookUpPayoffKeysByCodeUnitsNotByCanonicalEquivalence() {
    let states = Dictionary(jsEntries: [(key: "\u{E9}", value: VolumeState.goalMet)])
    #expect(resolvePromiseDueStanding(payoff(volume: "e\u{301}"), chapter: 1, volumeStates: states) == .notDue)
    #expect(resolvePromiseDueStanding(payoff(volume: "\u{E9}"), chapter: 1, volumeStates: states) == .overdue)
  }

  @Test func shouldLabelAThreadWithItsSummaryAndNeverCarryAMysteryOnlyField() {
    let item = threadPromiseItem(thread(), chapter: 5)
    #expect(item.kind == .thread && item.key == "thread-1" && item.label == "A thread" && item.resolvedChapter == nil && item.closedChapter == nil)
  }

  @Test func shouldFallBackToTheThreadKeyWhenTheSummaryIsBlank() {
    #expect(threadPromiseItem(thread { $0.summary = "  " }, chapter: 5).label == "thread-1")
    #expect(threadPromiseItem(thread { $0.summary = nil }, chapter: 5).label == "thread-1")
    #expect(threadPromiseItem(thread { $0.summary = "\u{FEFF}\u{A0}" }, chapter: 5).label == "thread-1")
  }

  @Test func shouldKeepAZeroWidthSpaceSummaryBecauseJavaScriptDoesNotTrimIt() {
    #expect(threadPromiseItem(thread { $0.summary = "\u{200B}" }, chapter: 5).label == "\u{200B}")
  }

  @Test func shouldCarryTheClosedChapterThrough() {
    #expect(threadPromiseItem(thread { $0.closedChapter = 9 }, chapter: 5).closedChapter == 9)
  }

  @Test func shouldLabelAMysteryWithItsQuestionAndOmitEveryTruthField() {
    let item = mysteryPromiseItem(mystery(), chapter: 5)
    #expect(item.kind == .mystery && item.key == "mystery-1" && item.label == "Who did it?" && item.closedChapter == nil)
  }

  @Test func shouldCarryTheResolvedChapterThrough() {
    #expect(mysteryPromiseItem(mystery { $0.resolvedChapter = 12 }, chapter: 20).resolvedChapter == 12)
  }

  @Test func shouldComputeOverdueForAMysteryPastItsChapterWindow() {
    #expect(mysteryPromiseItem(mystery { $0.payoff = payoff(window: 5) }, chapter: 10).due == .overdue)
  }

  @Test func shouldKeepTheLastValueWhenAJavaScriptKeyedMapRepeatsAKey() {
    let states = Dictionary(jsEntries: [(key: "k", value: VolumeState.active), (key: "k", value: VolumeState.goalMet)])
    #expect(states[JSString("k")] == .goalMet)
  }
}
