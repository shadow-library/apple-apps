import Foundation
import MemoirCore
import Testing

@Suite("LocalDate", TestTimeLimit.quick)
struct LocalDateTests {
  private static func date(_ string: String) throws -> LocalDate {
    try #require(LocalDate(isoString: string))
  }

  @Test("should count days from 1970-01-01")
  func countsFromEpoch() throws {
    #expect(try Self.date("1970-01-01").daysSinceEpoch == 0)
    #expect(try Self.date("1969-12-31").daysSinceEpoch == -1)
    #expect(try Self.date("2000-01-01").daysSinceEpoch == 10_957)
    #expect(try Self.date("2024-02-29").daysSinceEpoch == 19_782)
    #expect(try Self.date("0000-01-01").daysSinceEpoch == -719_528)
    #expect(try Self.date("9999-12-31").daysSinceEpoch == 2_932_896)
  }

  @Test("should walk every day from 1900 to 2100 in step with a month-length counter and round-trip through ISO text")
  func walksEveryDay() throws {
    var year = 1900
    var month = 1
    var day = 1
    var expected = try #require(LocalDate(year: 1900, month: 1, day: 1))
    while year <= 2100 {
      let date = try #require(LocalDate(daysSinceEpoch: expected.daysSinceEpoch))
      #expect(date.year == year && date.month == month && date.day == day)
      let text = date.isoString
      #expect(text == String(format: "%04d-%02d-%02d", year, month, day))
      #expect(LocalDate(isoString: text) == date)
      day += 1
      if day > LocalDate.daysInMonth(year: year, month: month) {
        day = 1
        month += 1
      }
      if month > 12 {
        month = 1
        year += 1
      }
      expected = try #require(expected.adding(days: 1))
    }
    #expect(expected.isoString == "2101-01-01")
  }

  @Test("should agree with the Gregorian calendar on the weekday of every day from 1900 to 2100")
  func matchesCalendarWeekdays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let first = try #require(LocalDate(year: 1900, month: 1, day: 1))
    let last = try #require(LocalDate(year: 2100, month: 12, day: 31))
    for offset in 0...last.days(since: first) {
      let date = try #require(first.adding(days: offset))
      let reference = calendar.component(.weekday, from: Date(timeIntervalSince1970: Double(date.daysSinceEpoch) * 86_400))
      #expect(date.weekday.rawValue == (reference + 5) % 7 + 1, "\(date)")
    }
  }

  @Test("should name the weekday of known dates")
  func namesWeekdays() throws {
    #expect(try Self.date("1970-01-01").weekday == .thursday)
    #expect(try Self.date("1969-12-28").weekday == .sunday)
    #expect(try Self.date("2000-01-01").weekday == .saturday)
    #expect(try Self.date("2024-02-26").weekday == .monday)
  }

  @Test("should follow the Gregorian leap year rule")
  func followsLeapYears() {
    #expect(LocalDate(year: 2024, month: 2, day: 29) != nil)
    #expect(LocalDate(year: 2000, month: 2, day: 29) != nil)
    #expect(LocalDate(year: 1900, month: 2, day: 29) == nil)
    #expect(LocalDate(year: 2100, month: 2, day: 29) == nil)
    #expect(LocalDate(year: 2023, month: 2, day: 29) == nil)
    #expect(LocalDate(year: 2024, month: 4, day: 31) == nil)
  }

  @Test("should add days across month, year and leap boundaries in both directions")
  func addsDays() throws {
    #expect(try Self.date("2024-02-28").adding(days: 1)?.isoString == "2024-02-29")
    #expect(try Self.date("2023-02-28").adding(days: 1)?.isoString == "2023-03-01")
    #expect(try Self.date("2023-12-31").adding(days: 1)?.isoString == "2024-01-01")
    #expect(try Self.date("2024-03-01").adding(days: -1)?.isoString == "2024-02-29")
    #expect(try Self.date("2024-03-01").adding(days: -366)?.isoString == "2023-03-01")
    #expect(try Self.date("2024-03-01").adding(days: 0) == Self.date("2024-03-01"))
  }

  @Test("should report nil past the 0000 to 9999 range and on integer overflow")
  func refusesOutOfRange() throws {
    #expect(try Self.date("9999-12-31").adding(days: 1) == nil)
    #expect(try Self.date("0000-01-01").adding(days: -1) == nil)
    #expect(try Self.date("2024-01-01").adding(days: .max) == nil)
    #expect(try Self.date("2024-01-01").adding(days: .min) == nil)
    #expect(LocalDate(daysSinceEpoch: LocalDate.latest.daysSinceEpoch + 1) == nil)
    #expect(LocalDate(daysSinceEpoch: LocalDate.earliest.daysSinceEpoch - 1) == nil)
    #expect(LocalDate.earliest.isoString == "0000-01-01")
    #expect(LocalDate.latest.isoString == "9999-12-31")
  }

  @Test("should round-trip every day of the supported range at its year, month and edge days")
  func roundTripsWholeRange() throws {
    for year in stride(from: 0, through: 9999, by: 7) {
      for month in 1...12 {
        for day in [1, LocalDate.daysInMonth(year: year, month: month)] {
          let date = try #require(LocalDate(year: year, month: month, day: day))
          #expect(LocalDate(daysSinceEpoch: date.daysSinceEpoch) == date)
          #expect(LocalDate(isoString: date.isoString) == date)
          #expect(date.year == year && date.month == month && date.day == day)
        }
      }
    }
  }

  @Test("should parse only zero-padded ASCII yyyy-MM-dd text of a real date")
  func refusesInvalidStrings() {
    let invalid = [
      "", "2024-1-01", "2024-01-1", "24-01-01", "2024/01/01", "2024-01-011", "20240101", "2024-13-01", "2024-00-10", "2024-01-00", "2024-02-30",
      "2023-02-29", " 2024-01-01", "2024-01-01 ", "2024-01-01T00:00:00Z", "+024-01-01", "-001-01-01", "2024-0a-01", "٢٠٢٤-٠١-٠١", "2024–01-01",
    ]
    for string in invalid { #expect(LocalDate(isoString: string) == nil, "\(string)") }
  }

  @Test("should order by day")
  func ordersByDay() throws {
    #expect(try Self.date("1999-12-31") < Self.date("2000-01-01"))
    #expect(try Self.date("0999-06-01") < Self.date("1000-01-01"))
    #expect(try Self.date("2000-01-01").days(since: Self.date("1999-12-31")) == 1)
    #expect(try [Self.date("2024-03-01"), Self.date("1969-07-20"), Self.date("2024-02-29")].sorted().map(\.isoString) == ["1969-07-20", "2024-02-29", "2024-03-01"])
  }

  @Test("should encode as the ISO string and refuse to decode anything else")
  func codesAsISOString() throws {
    let encoded = try JSONEncoder().encode(["day": Self.date("2024-02-29")])

    #expect(String(decoding: encoded, as: UTF8.self) == #"{"day":"2024-02-29"}"#)
    #expect(try JSONDecoder().decode([String: LocalDate].self, from: encoded) == ["day": Self.date("2024-02-29")])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([String: LocalDate].self, from: Data(#"{"day":"2023-02-29"}"#.utf8)) }
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([String: LocalDate].self, from: Data(#"{"day":19782}"#.utf8)) }
  }
}
