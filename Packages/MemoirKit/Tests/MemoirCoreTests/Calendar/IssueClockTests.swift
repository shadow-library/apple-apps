import Foundation
import MemoirCore
import Testing

@Suite("Issue clock", TestTimeLimit.quick)
struct IssueClockTests {
  private static let minute: Int64 = 60_000
  private static let hour: Int64 = 3_600_000

  private static func clock(_ identifier: String) throws -> IssueClock {
    IssueClock(timeZone: try #require(TimeZone(identifier: identifier)))
  }

  private static func date(_ text: String) throws -> LocalDate {
    try #require(LocalDate(isoString: text))
  }

  private static func utc(_ text: String) throws -> Int64 {
    let date = try #require(ISO8601DateFormatter().date(from: text))
    return Int64(date.timeIntervalSince1970 * 1000)
  }

  @Test("should resolve a New York spring-forward gap to the transition itself and never past it")
  func springForwardGap() throws {
    let clock = try Self.clock("America/New_York")
    let day = try Self.date("2024-03-10")
    let transition = try Self.utc("2024-03-10T07:00:00Z")
    for minuteOfDay in [120, 121, 150, 179] {
      let resolved = try clock.resolve(minuteOfDay: minuteOfDay, on: day)
      #expect(resolved.instantMillis == transition)
      #expect(resolved.resolution == .gapShifted && resolved.minuteOfDay == 180 && resolved.date == day)
    }
    #expect(clock.minuteOfDay(at: transition - 1) == 119)
    #expect(clock.utcOffsetMinutes(at: transition - 1) == -300)
    #expect(clock.utcOffsetMinutes(at: transition) == -240)
    #expect(try clock.resolve(minuteOfDay: 119, on: day).resolution == .exact)
    #expect(try clock.resolve(minuteOfDay: 180, on: day).instantMillis == clock.resolve(minuteOfDay: 150, on: day).instantMillis)
    #expect(try clock.resolve(minuteOfDay: 180, on: day).resolution == .exact)
    #expect(try clock.dayLengthMinutes(day) == 1380)
  }

  @Test("should resolve a repeated fall-back wall time to the earlier instant")
  func fallBackFold() throws {
    let clock = try Self.clock("America/New_York")
    let day = try Self.date("2024-11-03")
    let resolved = try clock.resolve(minuteOfDay: 90, on: day)
    #expect(resolved.resolution == .ambiguousEarlier)
    #expect(try resolved.instantMillis == Self.utc("2024-11-03T05:30:00Z"))
    #expect(clock.utcOffsetMinutes(at: resolved.instantMillis) == -240)
    #expect(clock.minuteOfDay(at: resolved.instantMillis + Self.hour) == 90)
    #expect(try clock.resolve(minuteOfDay: 59, on: day).resolution == .exact)
    #expect(try clock.resolve(minuteOfDay: 60, on: day).resolution == .ambiguousEarlier)
    #expect(try clock.resolve(minuteOfDay: 119, on: day).resolution == .ambiguousEarlier)
    #expect(try clock.resolve(minuteOfDay: 120, on: day).resolution == .exact)
    #expect(try clock.dayLengthMinutes(day) == 1500)
  }

  @Test("should handle half-hour shifts, quarter-hour offsets and a midnight that does not exist")
  func unusualZones() throws {
    let lordHowe = try Self.clock("Australia/Lord_Howe")
    let gap = try lordHowe.resolve(minuteOfDay: 135, on: Self.date("2024-10-06"))
    #expect(gap.resolution == .gapShifted && gap.minuteOfDay == 150)
    #expect(try lordHowe.resolve(minuteOfDay: 105, on: Self.date("2024-04-07")).resolution == .ambiguousEarlier)
    #expect(try lordHowe.dayLengthMinutes(Self.date("2024-10-06")) == 1410)
    #expect(try lordHowe.dayLengthMinutes(Self.date("2024-04-07")) == 1470)

    let chatham = try Self.clock("Pacific/Chatham")
    #expect(chatham.utcOffsetMinutes(at: try Self.utc("2024-07-01T00:00:00Z")) == 765)
    #expect(chatham.utcOffsetMinutes(at: try Self.utc("2024-01-01T00:00:00Z")) == 825)
    #expect(try Self.clock("Asia/Kathmandu").utcOffsetMinutes(at: Self.utc("2024-01-01T00:00:00Z")) == 345)
    #expect(try Self.clock("America/St_Johns").utcOffsetMinutes(at: Self.utc("2024-01-01T00:00:00Z")) == -210)

    let santiago = try Self.clock("America/Santiago")
    let midnight = try santiago.resolve(minuteOfDay: 0, on: Self.date("2024-09-08"))
    #expect(try midnight.resolution == .gapShifted && midnight.minuteOfDay == 60 && midnight.date == Self.date("2024-09-08"))
    #expect(try santiago.startOfDay(Self.date("2024-09-08")) == midnight.instantMillis)
  }

  @Test("should stamp an issued command with the offset in force and the local date, before 1970 too")
  func stamps() throws {
    let kiritimati = try Self.clock("Pacific/Kiritimati")
    let now = try Self.utc("2026-03-10T11:00:00Z")
    #expect(try kiritimati.stamp(at: now) == IssueStamp(instantMillis: now, utcOffsetMinutes: 840, issuedOn: Self.date("2026-03-11")))
    let utc = try Self.clock("UTC")
    #expect(try utc.zonedFields(at: -1) == ZonedFields(date: Self.date("1969-12-31"), minuteOfDay: 1439, second: 59))
    #expect(utc.minuteOfDay(at: -1) == 1439)
    #expect(try utc.accountToday(at: now, openDay: Self.date("2026-03-11")) == Self.date("2026-03-11"))
    #expect(try utc.accountToday(at: now, openDay: Self.date("2026-03-09")) == Self.date("2026-03-10"))
    #expect(try utc.accountToday(at: now, openDay: nil) == Self.date("2026-03-10"))
  }

  @Test("should look the offset up by the whole second, so a millisecond before a transition keeps the old offset")
  func millisecondsBeforeTransition() throws {
    let berlin = try Self.clock("Europe/Berlin")
    let transition = try Self.utc("2024-03-31T01:00:00Z")
    #expect(berlin.utcOffsetMinutes(at: transition - 1) == 60)
    #expect(berlin.utcOffsetMinutes(at: transition) == 120)
    #expect(try berlin.zonedFields(at: transition - 1) == ZonedFields(date: Self.date("2024-03-31"), minuteOfDay: 119, second: 59))
    #expect(try berlin.zonedFields(at: transition) == ZonedFields(date: Self.date("2024-03-31"), minuteOfDay: 180, second: 0))
  }

  @Test("should clamp a claim into the window from the later of the day start and the last sync up to now")
  func clamps() throws {
    let clock = try Self.clock("America/New_York")
    let day = try Self.date("2024-06-10")
    let start = try clock.startOfDay(day)
    let now = start + 20 * Self.hour
    func clamp(_ performed: Int64, lastAck: Int64? = nil, now: Int64 = now) throws -> ClampedPerformedAt {
      try clock.clamp(PerformedAtClaim(performedAtMillis: performed, nowMillis: now, lastAckedSyncMillis: lastAck, occurrenceDate: day))
    }
    #expect(try clamp(start - 1).outcome == .clampedToWindowStart)
    #expect(try clamp(start - 1).instantMillis == start)
    #expect(try clamp(start).outcome == .withinWindow)
    #expect(try clamp(now).outcome == .withinWindow)
    #expect(try clamp(now + 1).instantMillis == now)
    #expect(try clamp(now + 1).outcome == .clampedToNow)
    #expect(try clamp(start + Self.hour, lastAck: start + 8 * Self.hour).instantMillis == start + 8 * Self.hour)
    #expect(try clamp(start + 21 * Self.hour, lastAck: now + Self.hour).instantMillis == now)
    let early = try clamp(start, now: start - Self.hour)
    #expect(early.instantMillis == start - Self.hour && early.daysElapsed == -1 && early.outcome == .clampedToNow)
    let later = try clamp(start + 2 * 24 * Self.hour + 435 * Self.minute, now: start + 3 * 24 * Self.hour)
    #expect(try later.date == Self.date("2024-06-12") && later.minuteOfDay == 435 && later.daysElapsed == 2)
  }

  @Test("should refuse a minute outside the day and a date whose result leaves the years 0000 to 9999")
  func refusesOutOfRange() throws {
    let clock = try Self.clock("Pacific/Kiritimati")
    let day = try Self.date("2024-01-01")
    #expect(throws: CalendarError.minuteOfDayOutOfRange(1440)) { try clock.resolve(minuteOfDay: 1440, on: day) }
    #expect(throws: CalendarError.minuteOfDayOutOfRange(-1)) { try clock.resolve(minuteOfDay: -1, on: day) }
    #expect(throws: CalendarError.dateOutOfRange) { try clock.dayLengthMinutes(LocalDate.latest) }
    #expect(throws: CalendarError.dateOutOfRange) { try clock.zonedFields(at: 253_402_300_799_999) }
    let behindUTC = IssueClock(timeZone: try #require(TimeZone(secondsFromGMT: -3600)))
    #expect(throws: CalendarError.dateOutOfRange) { try behindUTC.localDate(at: -62_167_219_200_000) }
    #expect(throws: CalendarError.dateOutOfRange) { try clock.stamp(at: .max) }
    #expect((0..<1440).contains(clock.minuteOfDay(at: .max)) && (0..<1440).contains(clock.minuteOfDay(at: .min)))
  }
}
