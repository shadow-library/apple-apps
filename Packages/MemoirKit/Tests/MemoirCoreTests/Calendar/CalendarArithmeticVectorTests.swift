import MemoirCore
import Testing

@Suite("Calendar arithmetic vectors", TestTimeLimit.quick)
struct CalendarArithmeticVectorTests {
  private static func check(_ function: String, evaluate: (FixtureValue) throws -> FixtureValue) throws {
    try CalendarVectors.check("time.json", function, evaluate: evaluate)
  }

  private static func pair(_ input: FixtureValue) throws -> (FixtureValue, FixtureValue) {
    let items = try input.array
    guard items.count == 2 else { throw FixtureError.malformed("\(input) is not a pair") }
    return (items[0], items[1])
  }

  @Test("should agree with the reference on leap years, month lengths and month-end clamping")
  func monthLengths() throws {
    try Self.check("isLeapYear") { .bool(LocalDate.isLeapYear(try $0.int)) }
    try Self.check("daysInMonth") { input in
      let (year, month) = try Self.pair(input)
      return .int(LocalDate.daysInMonth(year: try year.int, month: try month.int))
    }
    try Self.check("clampToMonthEnd") { input in
      let parts = try input.array.map { try $0.int }
      return FixtureValue(try require(LocalDate.clampedToMonthEnd(year: parts[0], month: parts[1], day: parts[2]), "\(input) clamps to no date"))
    }
  }

  @Test("should agree with the reference on parsing, epoch days and day arithmetic")
  func epochDays() throws {
    try Self.check("parseLocalDate") { input in LocalDate(isoString: try input.string).map(FixtureValue.init) ?? .null }
    try Self.check("epochDayOf") { .int(try $0.localDate.daysSinceEpoch) }
    try Self.check("localDateFromEpochDay") { FixtureValue(try require(LocalDate(daysSinceEpoch: try $0.int), "\($0) is out of range")) }
    try Self.check("addDays") { input in
      let (from, days) = try Self.pair(input)
      return FixtureValue(try require(try from.localDate.adding(days: try days.int), "\(input) leaves the range"))
    }
    try Self.check("daysBetween") { input in
      let (from, to) = try Self.pair(input)
      return .int(try to.localDate.days(since: try from.localDate))
    }
    try Self.check("compareLocalDates") { input in
      let (left, right) = try Self.pair(input)
      let (lhs, rhs) = (try left.localDate, try right.localDate)
      return .int(lhs < rhs ? -1 : lhs == rhs ? 0 : 1)
    }
  }

  @Test("should agree with the reference on month arithmetic")
  func months() throws {
    try Self.check("addMonths") { input in
      let (from, months) = try Self.pair(input)
      return FixtureValue(try require(try from.localDate.adding(months: try months.int), "\(input) leaves the range"))
    }
    try Self.check("monthIndexOf") { .int(try $0.localDate.monthIndex) }
    try Self.check("nthWeekdayOfMonth") { input in
      let parts = try input.array
      let date = LocalDate.nthWeekday(try parts[2].weekday, try parts[3].ordinal, year: try parts[0].int, month: try parts[1].int)
      return FixtureValue(try require(date, "\(input) has no such weekday"))
    }
  }

  @Test("should agree with the reference on Monday-anchored weeks")
  func weeks() throws {
    try Self.check("weekdayOf") { .int(try $0.localDate.weekday.rawValue) }
    try Self.check("mondayWeekIndexOf") { .int(try $0.localDate.mondayWeekIndex) }
    try Self.check("startOfMondayWeek") { FixtureValue(try require(try $0.localDate.startOfMondayWeek, "\($0) has no Monday in range")) }
    try Self.check("weeksBetween") { input in
      let (from, to) = try Self.pair(input)
      return .int(try to.localDate.weeks(since: try from.localDate))
    }
  }

  @Test("should count years 0 to 99 as civil years where the reference's Date.UTC reads them as 1900 to 1999")
  func earlyYearsDiverge() throws {
    let list = try CalendarVectors.load(CalendarDivergenceList.self, "divergences.json")
    #expect(list.count == list.cases.count && !list.cases.isEmpty)
    for divergence in list.cases {
      let date = try FixtureValue.string(divergence.input).localDate
      #expect(date.daysSinceEpoch == divergence.exact && divergence.exact != divergence.reference, "\(divergence.input)")
      #expect(LocalDate(daysSinceEpoch: divergence.exact) == date)
    }
  }

  @Test("should report nil where arithmetic leaves the years 0000 to 9999 or a clamp has no day")
  func refusesOutOfRange() throws {
    let first = LocalDate.earliest
    let last = LocalDate.latest
    #expect(last.adding(months: 1) == nil)
    #expect(first.adding(months: -1) == nil)
    #expect(first.adding(months: .max) == nil)
    #expect(first.adding(months: .min) == nil)
    #expect(first.adding(months: .min + 5) == nil)
    #expect(last.adding(months: -(last.monthIndex + 1)) == nil)
    #expect(last.adding(months: -last.monthIndex)?.isoString == "0000-01-31")
    #expect(try #require(LocalDate(isoString: "2024-01-31")).adding(months: .min) == nil)
    #expect(first.startOfMondayWeek == nil)
    #expect(first.weekday == .saturday)
    #expect(LocalDate.clampedToMonthEnd(year: 2024, month: 2, day: 0) == nil)
    #expect(LocalDate.clampedToMonthEnd(year: 2024, month: 13, day: 1) == nil)
    #expect(LocalDate.clampedToMonthEnd(year: -1, month: 12, day: 31) == nil)
    #expect(LocalDate.clampedToMonthEnd(year: 10_000, month: 1, day: 1) == nil)
    #expect(LocalDate.nthWeekday(.monday, .first, year: 2024, month: 0) == nil)
    #expect(LocalDate.nthWeekday(.friday, .last, year: 9999, month: 12)?.isoString == "9999-12-31")
    #expect(LocalDate.clampedToMonthEnd(year: 2023, month: 2, day: .max)?.isoString == "2023-02-28")
  }
}
