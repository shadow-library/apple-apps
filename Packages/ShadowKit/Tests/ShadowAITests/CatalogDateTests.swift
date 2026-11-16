import Foundation
import Testing

@testable import ShadowAI

@Suite("CatalogDate")
struct CatalogDateTests {
  @Test(arguments: [
    ("2026-11-16", 2026, 11, 16),
    ("2024-02-29", 2024, 2, 29),
    ("0001-01-01", 1, 1, 1),
    ("9999-12-31", 9999, 12, 31),
  ])
  func shouldParseValidDates(text: String, year: Int, month: Int, day: Int) {
    let date = CatalogDate(text)
    #expect(date?.year == year)
    #expect(date?.month == month)
    #expect(date?.day == day)
    #expect(date?.description == text)
  }

  @Test(arguments: [
    "2026-13-01", "2026-00-10", "2026-02-29", "2026-04-31", "2026-01-00", "2026/11/16", "2026-1-16", "26-11-16", "2026-11-16T00:00", "", "abcd-ef-gh", "2026-11-1６", "+026-11-16",
    "0000-01-01",
  ])
  func shouldRejectInvalidDates(text: String) {
    #expect(CatalogDate(text) == nil)
  }

  @Test func shouldAcceptLeapDayOnlyInLeapYears() {
    #expect(CatalogDate(year: 2000, month: 2, day: 29) != nil)
    #expect(CatalogDate(year: 1900, month: 2, day: 29) == nil)
    #expect(CatalogDate(year: 2028, month: 2, day: 29) != nil)
    #expect(CatalogDate(year: 2027, month: 2, day: 29) == nil)
  }

  @Test func shouldOrderByCalendarDate() {
    #expect(CatalogFixtures.date("2026-01-31") < CatalogFixtures.date("2026-02-01"))
    #expect(CatalogFixtures.date("2025-12-31") < CatalogFixtures.date("2026-01-01"))
    #expect(CatalogFixtures.date("2026-03-09") < CatalogFixtures.date("2026-03-10"))
    #expect(!(CatalogFixtures.date("2026-03-10") < CatalogFixtures.date("2026-03-10")))
    #expect(CatalogFixtures.date("2026-03-10") == CatalogFixtures.date("2026-03-10"))
  }

  @Test(arguments: [
    ("2026-11-16", "2026-11-16", 0),
    ("2026-11-16", "2026-11-17", 1),
    ("2026-11-16", "2026-12-16", 30),
    ("2026-11-16", "2026-11-15", -1),
    ("2024-02-28", "2024-03-01", 2),
    ("2025-02-28", "2025-03-01", 1),
    ("2025-12-31", "2026-12-31", 365),
    ("2024-12-31", "2025-12-31", 365),
    ("2023-12-31", "2024-12-31", 366),
  ])
  func shouldCountDaysBetweenDates(from: String, to: String, expected: Int) {
    #expect(CatalogFixtures.date(from).days(until: CatalogFixtures.date(to)) == expected)
  }

  @Test(arguments: [
    (0.0, "1970-01-01"),
    (86_399.999, "1970-01-01"),
    (86_400.0, "1970-01-02"),
    (-0.001, "1969-12-31"),
    (1_783_900_800.0, "2026-07-13"),
    (1_783_900_799.999, "2026-07-12"),
    (951_782_400.0, "2000-02-29"),
  ])
  func shouldBuildFromDateInUTC(seconds: Double, expected: String) {
    #expect(CatalogDate(Date(timeIntervalSince1970: seconds)).description == expected)
  }

  @Test func shouldClampExtremeDates() {
    #expect(CatalogDate(Date.distantFuture).description == "4001-01-01")
    #expect(CatalogDate(Date.distantPast).description == "0001-01-01")
    #expect(CatalogDate(Date(timeIntervalSince1970: 1e15)).description == "9999-12-31")
    #expect(CatalogDate(Date(timeIntervalSince1970: -1e15)).description == "0001-01-01")
    #expect(CatalogDate(Date(timeIntervalSince1970: .nan)).description == "1970-01-01")
  }

  @Test func shouldRoundTripThroughJSONAsText() throws {
    let encoded = try JSONEncoder().encode([CatalogFixtures.date("2026-11-30")])
    #expect(String(decoding: encoded, as: UTF8.self) == "[\"2026-11-30\"]")
    #expect(try JSONDecoder().decode([CatalogDate].self, from: encoded) == [CatalogFixtures.date("2026-11-30")])
  }

  @Test func shouldFailToDecodeMalformedDate() {
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([CatalogDate].self, from: Data("[\"2026-02-30\"]".utf8)) }
  }
}
