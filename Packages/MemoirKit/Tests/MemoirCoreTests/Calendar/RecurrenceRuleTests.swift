import MemoirCore
import Testing

@Suite("Recurrence rules", TestTimeLimit.quick)
struct RecurrenceRuleTests {
  private static func date(_ text: String) throws -> LocalDate {
    try #require(LocalDate(isoString: text))
  }

  private static func dates(_ expansion: RecurrenceExpansion) -> [String] {
    expansion.occurrences.map(\.date.isoString)
  }

  @Test("should refuse a weekly rule without weekdays and a monthly day below 1, and accept a day past every month's end")
  func refusesMalformedRules() throws {
    let start = try Self.date("2024-01-01")
    #expect(throws: CalendarError.noWeekdays) { try RecurrenceRule(frequency: .weekly([]), startDate: start) }
    #expect(throws: CalendarError.dayOfMonthOutOfRange(0)) { try RecurrenceRule(frequency: .monthly(.dayOfMonth(0)), startDate: start) }
    #expect(throws: CalendarError.dayOfMonthOutOfRange(-5)) { try RecurrenceRule(frequency: .monthly(.dayOfMonth(-5)), startDate: start) }
    let late = try RecurrenceRule(frequency: .monthly(.dayOfMonth(40)), startDate: start)
    #expect(try Self.dates(late.expand(from: start, through: Self.date("2024-03-31"))) == ["2024-01-31", "2024-02-29", "2024-03-31"])
  }

  @Test("should clamp a leap-day anniversary in common years, the 2100 century included, and keep it under COUNT")
  func leapDays() throws {
    let rule = try RecurrenceRule(frequency: .yearly, startDate: Self.date("2096-02-29"), end: .count(6))
    #expect(
      try Self.dates(rule.expand(from: Self.date("2096-01-01"), through: Self.date("2110-12-31"))) == [
        "2096-02-29", "2097-02-28", "2098-02-28", "2099-02-28", "2100-02-28", "2101-02-28",
      ])
    let monthly = try RecurrenceRule(frequency: .monthly(.dayOfMonth(29)), startDate: Self.date("2100-01-29"))
    #expect(try Self.dates(monthly.expand(from: Self.date("2100-01-01"), through: Self.date("2100-03-31"))) == ["2100-01-29", "2100-02-28", "2100-03-29"])
  }

  @Test("should spend a COUNT slot on an exception and stop at the earlier of COUNT and the window")
  func countWithExceptions() throws {
    let rule = try RecurrenceRule(frequency: .daily, startDate: Self.date("2024-01-01"), end: .count(3), exceptions: [Self.date("2024-01-01"), Self.date("2024-01-03")])
    let expansion = try rule.expand(from: Self.date("2024-01-01"), through: Self.date("2024-12-31"))
    #expect(Self.dates(expansion) == ["2024-01-02"])
    #expect(try expansion.cursor == RecurrenceOccurrence(date: Self.date("2024-01-03"), index: 2))
    #expect(try rule.nextOccurrence(onOrAfter: Self.date("2024-01-03")) == nil)
    #expect(try RecurrenceRule(frequency: .daily, startDate: Self.date("2024-01-01"), end: .count(-4)).nextOccurrence(onOrAfter: Self.date("2024-01-01")) == nil)
  }

  @Test("should honour a cursor exactly at the window start and ignore one after it, before the start date or with a negative index")
  func cursorBoundaries() throws {
    let rule = try RecurrenceRule(frequency: .daily, interval: 2, startDate: Self.date("2024-01-01"), end: .count(10))
    let from = try Self.date("2024-01-05")
    let through = try Self.date("2024-01-09")
    let expected = rule.expand(from: from, through: through)
    #expect(expected.occurrences.map(\.index) == [2, 3, 4])
    for cursor in [
      RecurrenceOccurrence(date: from, index: 2), RecurrenceOccurrence(date: try Self.date("2024-01-07"), index: 3),
      RecurrenceOccurrence(date: try Self.date("2023-12-31"), index: 0),
      RecurrenceOccurrence(date: try Self.date("2024-01-03"), index: -1),
    ] {
      #expect(rule.expand(from: from, through: through, resumingAt: cursor) == expected, "\(cursor)")
    }
    let inverted = rule.expand(from: through, through: from)
    #expect(inverted.occurrences.isEmpty && inverted.cursor == nil)
  }

  @Test("should stop at the end of year 9999 instead of trapping, for any interval or cursor index")
  func rangeEdges() throws {
    let last = LocalDate.latest
    let lateStart = try #require(last.adding(days: -3))
    let daily = try RecurrenceRule(frequency: .daily, startDate: lateStart)
    #expect(daily.expand(from: lateStart, through: last).occurrences.count == 4)
    #expect(daily.nextOccurrence(onOrAfter: last, resumingAt: RecurrenceOccurrence(date: last, index: .max)) == RecurrenceOccurrence(date: last, index: .max))
    #expect(daily.expand(from: lateStart, through: last, resumingAt: RecurrenceOccurrence(date: lateStart, index: .max)).occurrences.count == 1)
    for frequency in [RecurrenceRule.Frequency.daily, .weekly([.monday, .sunday]), .monthly(.dayOfMonth(31)), .yearly] {
      let huge = try RecurrenceRule(frequency: frequency, interval: .max, startDate: Self.date("2024-01-01"))
      #expect(try huge.expand(from: Self.date("2024-01-01"), through: last).occurrences.count <= 2, "\(frequency)")
      #expect(try huge.nextOccurrence(onOrAfter: Self.date("2025-01-01")) == nil, "\(frequency)")
    }
    let earliestWeek = try RecurrenceRule(frequency: .weekly([.monday, .saturday]), startDate: LocalDate.earliest)
    #expect(try Self.dates(earliestWeek.expand(from: LocalDate.earliest, through: Self.date("0000-01-10"))) == ["0000-01-01", "0000-01-03", "0000-01-08", "0000-01-10"])
  }

  @Test("should advance subscriptions by the reference's cycle rules and refuse a billing day outside 1 to 31")
  func subscriptionCycles() throws {
    #expect(throws: CalendarError.billingDayOutOfRange(0)) { try SubscriptionCycle(frequency: .monthly, billingDay: 0) }
    #expect(throws: CalendarError.billingDayOutOfRange(32)) { try SubscriptionCycle(frequency: .monthly, billingDay: 32) }
    let monthly = try SubscriptionCycle(frequency: .monthly, billingDay: 31)
    #expect(try monthly.advanceDueDate(from: Self.date("2026-02-28"))?.isoString == "2026-03-31")
    #expect(try SubscriptionCycle(frequency: .custom(intervalDays: nil), billingDay: 1).advanceDueDate(from: Self.date("2026-08-10"))?.isoString == "2026-09-09")
    #expect(try SubscriptionCycle(frequency: .custom(intervalDays: 0), billingDay: 1).advanceDueDate(from: Self.date("2026-08-10"))?.isoString == "2026-08-10")
    #expect(try SubscriptionCycle(frequency: .yearly, billingDay: 31).advanceDueDate(from: Self.date("9999-01-31")) == nil)
  }
}
