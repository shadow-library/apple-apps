import Foundation
import MemoirCore
import Testing

@Suite("Issue clock vectors", TestTimeLimit.standard)
struct IssueClockVectorTests {
  private static func clock(_ input: FixtureValue) throws -> IssueClock {
    let identifier = try input["zone"].string
    return IssueClock(timeZone: try require(TimeZone(identifier: identifier), "Foundation has no zone \(identifier)"))
  }

  @Test("should read the local fields and UTC offset of an instant as ICU does")
  func zonedFields() throws {
    try CalendarVectors.check("zones.json", "zonedFieldsAt") { input in
      let fields = try Self.clock(input).zonedFields(at: try input["instant"].int64)
      return .object(["date": FixtureValue(fields.date), "minuteOfDay": .int(fields.minuteOfDay), "second": .int(fields.second)])
    }
    try CalendarVectors.check("zones.json", "offsetMinutesAt") { input in
      .int(try Self.clock(input).utcOffsetMinutes(at: try input["instant"].int64))
    }
  }

  @Test("should resolve local minutes through gaps and folds as the reference does")
  func localMinutes() throws {
    try CalendarVectors.check("zones.json", "instantAtLocalMinute") { input in
      let resolved = try Self.clock(input).resolve(minuteOfDay: try input["minuteOfDay"].int, on: try input["date"].localDate)
      return .object([
        "instant": FixtureValue(resolved.instantMillis), "date": FixtureValue(resolved.date), "minuteOfDay": .int(resolved.minuteOfDay),
        "resolution": .string(resolved.resolution.rawValue),
      ])
    }
  }

  @Test("should start and measure local days as the reference does")
  func localDays() throws {
    try CalendarVectors.check("zones.json", "startOfLocalDay") { input in
      FixtureValue(try Self.clock(input).startOfDay(try input["date"].localDate))
    }
    try CalendarVectors.check("zones.json", "localDayLengthMinutes") { input in
      .int(try Self.clock(input).dayLengthMinutes(try input["date"].localDate))
    }
  }

  @Test("should clamp claimed instants and pick the account's day as the reference does")
  func clampsAndToday() throws {
    try CalendarVectors.check("zones.json", "clampPerformedAt") { input in
      let claim = PerformedAtClaim(
        performedAtMillis: try input["performedAt"].int64, nowMillis: try input["serverNow"].int64,
        lastAckedSyncMillis: try input["lastAckedSyncAt"].optionalInt.map(Int64.init), occurrenceDate: try input["occurrenceDate"].localDate)
      let clamped = try Self.clock(input).clamp(claim)
      return .object([
        "instant": FixtureValue(clamped.instantMillis), "date": FixtureValue(clamped.date), "minuteOfDay": .int(clamped.minuteOfDay),
        "daysElapsed": .int(clamped.daysElapsed), "outcome": .string(clamped.outcome.rawValue),
      ])
    }
    try CalendarVectors.check("zones.json", "accountToday") { input in
      let openDay: LocalDate? = if case .null = try input["lastHpDate"] { nil } else { try input["lastHpDate"].localDate }
      return FixtureValue(try Self.clock(input).accountToday(at: try input["instant"].int64, openDay: openDay))
    }
  }

  @Test("should name only zone exclusions that carry a reason")
  func exclusionsAreListed() throws {
    let list = try CalendarVectors.load(ZoneExclusionList.self, "zone-exclusions.json")
    #expect(list.count == list.cases.count)
    #expect(list.cases.allSatisfy { !$0.reason.isEmpty })
  }
}
