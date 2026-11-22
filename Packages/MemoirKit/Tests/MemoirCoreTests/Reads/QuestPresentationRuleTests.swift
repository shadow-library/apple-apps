import Foundation
import Testing

@testable import MemoirCore

@Suite("Memoir quest presentation rules", TestTimeLimit.quick)
struct QuestPresentationRuleTests {
  private static let start = LocalDate(year: 2026, month: 3, day: 2)!

  /// `features/quests/quest-presenters.ts:100-118` (`WEEKDAY_RANGE_MIN = 3`, `:38`).
  @Test func shouldReadThreeOrMoreDaysInARowAsARangeAndEveryDayAsEveryDay() {
    #expect(WeekdaySpan(Set(LocalDate.Weekday.allCases)) == .everyDay)
    #expect(WeekdaySpan([.monday, .tuesday, .wednesday, .friday]) == .days([.range(from: .monday, through: .wednesday), .single(.friday)]))
    #expect(WeekdaySpan([.monday, .wednesday]) == .days([.single(.monday), .single(.wednesday)]))
    #expect(WeekdaySpan([.saturday, .sunday, .monday]) == .days([.single(.monday), .single(.saturday), .single(.sunday)]), "the week runs Monday first")
    #expect(WeekdaySpan([.tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]) == .days([.range(from: .tuesday, through: .sunday)]))
  }

  /// `quest-presenters.ts:120-140`; an interval below 1 reads as 1, as replay reads it.
  @Test func shouldSummariseEveryFrequency() throws {
    #expect(RecurrenceSummary(try RecurrenceRule(frequency: .daily, interval: 0, startDate: Self.start)) == .daily(interval: 1))
    #expect(RecurrenceSummary(try RecurrenceRule(frequency: .daily, interval: 3, startDate: Self.start)) == .daily(interval: 3))
    #expect(
      RecurrenceSummary(try RecurrenceRule(frequency: .weekly([.monday, .friday]), interval: 2, startDate: Self.start))
        == .weekly(interval: 2, days: .days([.single(.monday), .single(.friday)])))
    #expect(RecurrenceSummary(try RecurrenceRule(frequency: .monthly(.dayOfMonth(31)), startDate: Self.start)) == .monthlyOnDay(interval: 1, day: 31))
    #expect(
      RecurrenceSummary(try RecurrenceRule(frequency: .monthly(.nthWeekday(.sunday, .last)), interval: 2, startDate: Self.start))
        == .monthlyOnWeekday(interval: 2, weekday: .sunday, ordinal: .last))
    #expect(RecurrenceSummary(try RecurrenceRule(frequency: .yearly, startDate: Self.start)) == .yearly(interval: 1, month: 3, day: 2))
  }

  /// `quest-presenters.ts:145-147`.
  @Test func shouldCountAStreakInDaysOnlyForAQuestThatRunsEveryDay() throws {
    #expect(try RecurrenceRule(frequency: .daily, startDate: Self.start).streakUnit == .days)
    #expect(try RecurrenceRule(frequency: .daily, interval: 2, startDate: Self.start).streakUnit == .occurrences)
    #expect(try RecurrenceRule(frequency: .weekly(Set(LocalDate.Weekday.allCases)), startDate: Self.start).streakUnit == .occurrences)
  }

  /// `quest-commands.service.ts:65-66`: the reschedules of the seven days ending on the occurrence; the cap frees once the window slides past them.
  @Test func shouldCountTheRescheduleBudgetOverTheSevenDaysEndingOnTheOccurrence() {
    let day = { (offset: Int) in Self.start.movedBy(days: offset) }
    #expect(RescheduleBudget.of([], on: day(0)) == RescheduleBudget(used: 0, cap: 2, bookedAhead: 0, freesOn: nil))
    #expect(RescheduleBudget.of([day(-7), day(-6)], on: day(0)) == RescheduleBudget(used: 1, cap: 2, bookedAhead: 0, freesOn: nil), "day −7 has left the window")
    #expect(RescheduleBudget.of([day(-6), day(0), day(3)], on: day(0)) == RescheduleBudget(used: 2, cap: 2, bookedAhead: 1, freesOn: day(1)))
    #expect(
      RescheduleBudget.of([day(-2), day(-1), day(5)], on: day(0)) == RescheduleBudget(used: 2, cap: 2, bookedAhead: 1, freesOn: day(6)),
      "a booked reschedule ahead keeps the cap bound until both earlier ones leave the window")
  }

  /// `lib/data/sleep-window.rules.ts:33-36`.
  @Test func shouldCountTheWakeWindowLeftAcrossMidnight() throws {
    let evening = try #require(ScheduleWindow(start: 360, end: 1380))
    #expect(evening.minutesUntilSleep(from: 1200) == 180 && evening.minutesUntilSleep(from: 1400) == -20)
    let afterMidnight = try #require(ScheduleWindow(start: 480, end: 60))
    #expect(afterMidnight.minutesUntilSleep(from: 30) == 30 && afterMidnight.minutesUntilSleep(from: 1380) == 120)
  }

  /// `fixture-provider.ts:519-521`.
  @Test func shouldReadAnOccurrenceStillOpenOrOnlyMovedOnAPassedDayAsMissed() async throws {
    let device = try ReadsDevice()
    try await device.create(ReadsDevice.routine, "Run", schedule: try ReadsDevice.schedule(.routine, start: 480))
    try await device.walk(to: ReadsDevice.day(1))
    let today = try await device.board(ReadsDevice.day(1)).occurrence(of: ReadsDevice.routine)
    #expect(today.status == .open && today.effectiveState == nil)
    let tomorrow = try await device.board(ReadsDevice.day(2)).occurrence(of: ReadsDevice.routine)
    #expect(tomorrow.status == .upcoming && tomorrow.effectiveState == nil)
  }
}
