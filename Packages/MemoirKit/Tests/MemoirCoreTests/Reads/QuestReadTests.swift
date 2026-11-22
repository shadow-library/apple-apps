import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir quest list, detail, streak board, plan and draft preview", TestTimeLimit.quick)
struct QuestReadTests {
  private typealias Device = ReadsDevice
  private static let cafe = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000f011")
  private static let read = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000f012")
  private static let unnamed = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000f013")
  private static let late = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000f014")

  /// "Café run" kept on days 0, 1 and 4, partial on day 2 and postponed on day 3; "Read" deleted; a goal without words; a quest created on day 3.
  private static func listDevice() async throws -> Device {
    let device = try Device()
    try await device.create(cafe, "Café run", schedule: try Device.schedule(.routine, start: 480, duration: 60))
    try await device.create(read, "Read", schedule: try Device.schedule(.anchor, start: 420))
    try await device.create(unnamed, nil, schedule: try Device.schedule(.goal, duration: 45))
    try await device.issue(.questDelete(QuestReference(questId: read)), on: Device.day(0), minute: 2)
    for (day, body) in [
      (0, MemoirCommandBody.questComplete(Occurrence(quest: cafe, date: Device.day(0)))), (1, .questComplete(Occurrence(quest: cafe, date: Device.day(1)))),
      (2, .questPartial(Occurrence(quest: cafe, date: Device.day(2)))), (3, .questPostpone(QuestBreak(occurrence: Occurrence(quest: cafe, date: Device.day(3))))),
      (4, .questComplete(Occurrence(quest: cafe, date: Device.day(4)))),
    ] {
      if day == 3 { try await device.create(late, "Late starter", schedule: try Device.schedule(.goal, recurrence: try Device.daily(from: Device.day(3))), on: Device.day(3)) }
      try await device.issue(body, on: Device.day(day), minute: 490)
    }
    try await device.walk(to: Device.day(4))
    return device
  }

  @Test func shouldFilterTheListByActivityAndSearchNamesIgnoringCaseAndDiacritics() async throws {
    let device = try await Self.listDevice()
    #expect(try await device.load(QuestList.self, QuestListQuery(filter: .active)).entries.map(\.id) == [Self.cafe, Self.unnamed, Self.late])
    #expect(try await device.load(QuestList.self, QuestListQuery(filter: .inactive)).entries.map(\.id) == [Self.read])
    #expect(try await device.load(QuestList.self, QuestListQuery(filter: .all)).entries.map(\.id) == [Self.cafe, Self.read, Self.unnamed, Self.late])
    #expect(try await device.load(QuestList.self, QuestListQuery(filter: .all, search: " CAFE ")).entries.map(\.id) == [Self.cafe])
    #expect(try await device.load(QuestList.self, QuestListQuery(filter: .all, search: "a")).entries.map(\.id) == [Self.cafe, Self.read, Self.late], "no name, no match")
    let unnamed = try #require(try await device.load(QuestList.self, QuestListQuery()).entries.first { $0.id == Self.unnamed })
    #expect(unnamed.quest.name == nil && unnamed.quest.strictness == .goal)
  }

  /// `lib/data/reflect.derive.ts:131-170` and `lib/sync/projection.ts:225-245`: a partial holds half, a postponed occurrence is counted where it moved.
  @Test func shouldMeasureAdherenceOverThirtyDaysWithAPartialAsHalf() async throws {
    let device = try await Self.listDevice()
    let entries = try await device.load(QuestList.self, QuestListQuery()).entries
    let cafe = try #require(entries.first { $0.id == Self.cafe })
    #expect(cafe.adherence.held == Halves(7) && cafe.adherence.occurrences == 4 && cafe.adherence.ratio == Fraction(numerator: 7, denominator: 8))
    #expect(cafe.streak.standing == .running(days: 1) && cafe.streak.longestDays == 3, "the postpone broke the run")
    let late = try #require(entries.first { $0.id == Self.late })
    #expect(late.adherence.occurrences == 1 && late.adherence.ratio == nil, "fewer than three counted occurrences give no ratio")
    #expect(cafe.xpEarned > 0)
  }

  @Test func shouldShowAQuestsHistoryTotalsAndShareOfTheWeek() async throws {
    let device = try await Self.listDevice()
    let detail = try await device.load(QuestDetail.self, QuestDetailQuery(quest: Self.cafe, historyLimit: 2))
    #expect(detail.history.map(\.date) == [Device.day(4), Device.day(3)] && detail.history.map(\.log.state) == [.completed, .postponed])
    #expect(detail.totals.byState == [.completed: 3, .partial: 1, .postponed: 1] && detail.totals.xp == detail.summary?.xpEarned)
    #expect(detail.today?.status == .recorded(.completed) && detail.scheduleEdit == .available)
    #expect(detail.load?.daysPerWeek == Fraction(7) && detail.load?.weeklyMinutes == Fraction(420))
    #expect(detail.load?.share == Fraction(numerator: 420, denominator: 420 + 315 + 210), "fixture-provider.ts:603-606: against every active quest's week")
    let missing = try await device.load(QuestDetail.self, QuestDetailQuery(quest: MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000ffff")))
    #expect(missing.summary == nil && missing.history.isEmpty && missing.load == nil)
    #expect(try await device.load(QuestDetail.self, QuestDetailQuery(quest: Self.read)).scheduleEdit == .unavailable(.questInactive))
  }

  /// `fixture-provider.ts:340-376`: the longest current runs first, and a run of a week or more that ended names the day it closed, the first
  /// unshielded break after its last kept day.
  @Test func shouldRankTheStreakBoardAndDateTheEndOfARunThatHadReachedAWeek() async throws {
    let device = try Device()
    let quests = (1...4).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-00000000f1%02d", $0)) }
    for (index, quest) in quests.enumerated() { try await device.create(quest, "Quest \(index)", schedule: try Device.schedule(.routine, start: 480)) }
    for day in 0...10 {
      let keeping = [quests[0]] + (day <= 2 ? [quests[1]] : []) + (day <= 7 ? [quests[2]] : [])
      for quest in keeping { try await device.issue(.questComplete(Occurrence(quest: quest, date: Device.day(day))), on: Device.day(day), minute: 490) }
    }
    try await device.walk(to: Device.day(10))
    let board = try await device.load(StreakBoard.self, StreakBoardQuery(date: Device.day(10)))

    #expect(board.entries.map(\.quest) == Array(quests.prefix(3)), "ties keep creation order and the limit is three")
    #expect(board.entries[0].streak.standing == .running(days: 11) && !board.entries[0].showsEnd)
    #expect(board.entries[1].streak.standing == .ended(longestDays: 3) && !board.entries[1].showsEnd && board.entries[1].endedOn == nil)
    let ended = board.entries[2]
    #expect(ended.showsEnd && ended.endedOn == Device.day(9), "day 8's miss was shielded, so the run ended on day 9")
    #expect(ended.week.map(\.date) == (4...10).map(Device.day))
    #expect(ended.week.map(\.state) == [.completed, .completed, .completed, .completed, .missed, .missed, nil])
    #expect(ended.week.map(\.shielded) == [false, false, false, false, true, false, false])
  }

  @Test func shouldLayOutTheWeekWithLoadsLocksTheCarryOverAndTheBusiestReschedule() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    for quest in [Device.anchor, Device.goal, Device.optional] {
      try await device.issue(.questComplete(Occurrence(quest: quest, date: Device.day(0))), on: Device.day(0), minute: 425)
    }
    try await device.issue(.questReschedule(try QuestReschedule(occurrence: Occurrence(quest: Device.anchor, date: Device.day(1)), toMinute: 600)), on: Device.day(1))
    try await device.issue(.planSetLock(try PlanLock(locking: [Device.anchor])), on: Device.day(1))
    try await device.walk(to: Device.day(1))
    let plan = try await device.load(PlanBoard.self, PlanBoardQuery(scope: .week(containing: Device.day(3))))

    #expect(plan.weekStart == .monday && plan.from == Device.day(0) && plan.through == Device.day(6) && plan.days.map(\.date) == (0...6).map(Device.day))
    #expect(plan.days.allSatisfy { $0.load == DayLoad(minutes: 150, occurrences: 4) && !$0.load.isOverCapacity })
    #expect(plan.days[1].lockNote == .locked && plan.days[1].lock == .active && plan.days[0].lockNote == nil)
    #expect(plan.carryOver == CarryOver(missed: 1, quest: Device.routine, name: "Run", longestDays: 0, streakEnded: false))
    #expect(plan.busiestReschedule?.quest == Device.anchor && plan.busiestReschedule?.budget.used == 1)
    #expect(plan.glance.scheduled == 28 && plan.glance.completed == 3 && plan.glance.shields.cap == 3 * Ruleset.v1.shields.capPerQuest)
    #expect(plan.crown?.periodStart == Device.day(1) && plan.lockCapacity != nil && plan.month == nil)
    let elsewhere = try await device.load(PlanBoard.self, PlanBoardQuery(scope: .week(containing: Device.day(10))))
    #expect(elsewhere.carryOver == nil, "only the week holding the open day carries yesterday over")
  }

  @Test func shouldStartTheWeekOnSundayWhenTheAccountSaysSo() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    let home = try #require(CurrencyCode("EUR"))
    _ = try await device.store.write { transaction in
      try AccountSettingsRecord(defaultCurrency: home, enabledCurrencies: [home], weekStart: 0).create(in: &transaction)
    }
    try await device.walk(to: Device.day(0))
    let plan = try await device.load(PlanBoard.self, PlanBoardQuery(scope: .week(containing: Device.day(3))))
    #expect(plan.weekStart == .sunday && plan.from == Device.day(-1) && plan.days.first?.relation == .past)
  }

  /// `fixture-provider.ts:558-573`: whole weeks from the one holding the 1st, outcomes only inside the month.
  @Test func shouldGridAMonthInWholeWeeks() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.walk(to: Device.day(2))
    let plan = try await device.load(PlanBoard.self, PlanBoardQuery(scope: .month(containing: Device.day(10))))
    let month = try #require(plan.month)
    #expect(month.first?.date == LocalDate(year: 2026, month: 2, day: 23) && month.last?.date == LocalDate(year: 2026, month: 4, day: 5) && month.count == 42)
    #expect(month.count(where: \.isInMonth) == 31 && plan.from == LocalDate(year: 2026, month: 3, day: 1) && plan.through == LocalDate(year: 2026, month: 3, day: 31))
    let monday = try #require(month.first { $0.date == Device.day(0) })
    #expect(monday.outcomes == [.missed, .missed, .missed, .missed] && monday.relation == .past)
    #expect(month.first { $0.date == Device.day(5) }?.outcomes == [nil, nil, nil, nil])
    #expect(month.first?.outcomes == [], "outside the month")
  }

  /// `fixture-provider.ts:608-631` and `quest-builder-screen.tsx:159-166`.
  @Test func shouldPreviewADraftsWeekWithoutWritingAnything() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.walk(to: Device.day(0))
    let before = try await device.store.pendingChanges(limit: Int.max).count

    let adding = QuestDraft(name: "Swim", strictness: .routine, startTimeMinutes: 1080, durationMinutes: 45, recurrence: try Device.daily())
    let added = try await device.load(DraftPreview.self, DraftPreviewQuery(draft: adding))
    #expect(added.isValid && added.days.map(\.minutes) == Array(repeating: 195, count: 7) && added.days.map(\.offset) == Array(0..<7))
    #expect(added.overload?.date == Device.day(0) && added.dailyCadence == 7 && added.scheduleEdit == .available)

    var editing = adding
    editing.editing = Device.routine
    let edited = try await device.load(DraftPreview.self, DraftPreviewQuery(draft: editing))
    #expect(edited.days.allSatisfy { $0.minutes == 135 } && edited.overload == nil, "the edited quest's own occurrences are replaced")

    let everyOther = QuestDraft(name: "Swim", strictness: .goal, recurrence: try Device.daily(from: Device.day(5), interval: 2))
    let later = try await device.load(DraftPreview.self, DraftPreviewQuery(draft: everyOther))
    #expect(later.days.first?.date == Device.day(5) && later.days.first?.offset == 5 && later.dailyCadence == 4)
    #expect(later.days.map(\.draftRuns) == [true, false, true, false, true, false, true])

    let weekly = QuestDraft(name: "Swim", strictness: .goal, recurrence: try RecurrenceRule(frequency: .weekly([.monday]), startDate: Device.monday))
    #expect(try await device.load(DraftPreview.self, DraftPreviewQuery(draft: weekly)).dailyCadence == nil)

    let broken = QuestDraft(name: "  ", strictness: .anchor, durationMinutes: 241, recurrence: try Device.daily(interval: 31))
    #expect(
      try await device.load(DraftPreview.self, DraftPreviewQuery(draft: broken)).issues == [
        .nameRequired, .intervalOutOfRange(31), .anchorNeedsStartTime, .durationOutOfRange(241),
      ])
    #expect(try await device.store.pendingChanges(limit: Int.max).count == before)
  }
}
