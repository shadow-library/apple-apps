import Foundation

public struct ZonedFields: Sendable, Hashable {
  public let date: LocalDate
  public let minuteOfDay: Int
  public let second: Int

  public init(date: LocalDate, minuteOfDay: Int, second: Int) {
    self.date = date
    self.minuteOfDay = minuteOfDay
    self.second = second
  }
}

public enum LocalMinuteResolution: String, Sendable, Hashable {
  case exact
  case ambiguousEarlier = "ambiguous_earlier"
  case gapShifted = "gap_shifted"
}

public struct ResolvedLocalMinute: Sendable, Hashable {
  public let instantMillis: Int64
  public let date: LocalDate
  public let minuteOfDay: Int
  public let resolution: LocalMinuteResolution
}

public struct IssueStamp: Sendable, Hashable {
  public let instantMillis: Int64
  public let utcOffsetMinutes: Int
  public let issuedOn: LocalDate

  public init(instantMillis: Int64, utcOffsetMinutes: Int, issuedOn: LocalDate) {
    self.instantMillis = instantMillis
    self.utcOffsetMinutes = utcOffsetMinutes
    self.issuedOn = issuedOn
  }
}

public struct PerformedAtClaim: Sendable, Hashable {
  public var performedAtMillis: Int64
  public var nowMillis: Int64
  public var lastAckedSyncMillis: Int64?
  public var occurrenceDate: LocalDate

  public init(performedAtMillis: Int64, nowMillis: Int64, lastAckedSyncMillis: Int64?, occurrenceDate: LocalDate) {
    self.performedAtMillis = performedAtMillis
    self.nowMillis = nowMillis
    self.lastAckedSyncMillis = lastAckedSyncMillis
    self.occurrenceDate = occurrenceDate
  }
}

public enum PerformedAtOutcome: String, Sendable, Hashable {
  case withinWindow = "within_window"
  case clampedToWindowStart = "clamped_to_window_start"
  case clampedToNow = "clamped_to_server_now"
}

public struct ClampedPerformedAt: Sendable, Hashable {
  public let instantMillis: Int64
  public let date: LocalDate
  public let minuteOfDay: Int
  /// Local days from the occurrence's date to the clamped instant's date: the timing band's day input.
  public let daysElapsed: Int
  public let outcome: PerformedAtOutcome
}

/// The device's time zone, read only while issuing a command; replay uses the offsets and dates the commands recorded.
public struct IssueClock: Sendable {
  public let timeZone: TimeZone

  public init(timeZone: TimeZone) {
    self.timeZone = timeZone
  }

  public static var current: IssueClock { IssueClock(timeZone: .current) }

  /// The clock of a zone a command named; nil when this device's zone data does not know it.
  public init?(zoneIdentifier: String) {
    guard let zone = TimeZone(identifier: zoneIdentifier) else { return nil }
    self.init(timeZone: zone)
  }

  /// A clock that keeps one offset, for a zone this device's data lacks; nil outside the offsets a zone can have.
  public init?(fixedOffsetMinutes: Int) {
    let (seconds, overflow) = fixedOffsetMinutes.multipliedReportingOverflow(by: 60)
    guard !overflow, let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
    self.init(timeZone: zone)
  }

  /// `issuedOn` comes from the recorded whole-minute offset, as `MemoirCommand` checks it, so in a zone whose offset has seconds it can differ
  /// from `localDate(at:)` in the seconds around midnight.
  public func stamp(at instantMillis: Int64) throws(CalendarError) -> IssueStamp {
    let offsetMinutes = Self.floorDivide(offsetSeconds(at: instantMillis), 60)
    let (local, overflow) = instantMillis.addingReportingOverflow(offsetMinutes * Self.millisPerMinute)
    guard !overflow, let day = Int(exactly: Self.floorDivide(local, Self.millisPerDay)), let issuedOn = LocalDate(daysSinceEpoch: day) else { throw .dateOutOfRange }
    return IssueStamp(instantMillis: instantMillis, utcOffsetMinutes: Int(offsetMinutes), issuedOn: issuedOn)
  }

  /// Whole minutes; an offset with seconds (local mean time, before 1972) rounds toward negative infinity.
  public func utcOffsetMinutes(at instantMillis: Int64) -> Int {
    Int(Self.floorDivide(offsetSeconds(at: instantMillis), 60))
  }

  public func zonedFields(at instantMillis: Int64) throws(CalendarError) -> ZonedFields {
    try Self.fields(at: instantMillis, offsetSeconds: offsetSeconds(at: instantMillis))
  }

  public func localDate(at instantMillis: Int64) throws(CalendarError) -> LocalDate {
    try zonedFields(at: instantMillis).date
  }

  public func minuteOfDay(at instantMillis: Int64) -> Int {
    Int(Self.floorModulo(Self.wallSeconds(at: instantMillis, offsetSeconds: offsetSeconds(at: instantMillis)), Self.secondsPerDay) / 60)
  }

  /// The open day: the zone's date, unless a backward zone change left the account's open day ahead of it.
  public func accountToday(at instantMillis: Int64, openDay: LocalDate?) throws(CalendarError) -> LocalDate {
    let zoneDay = try localDate(at: instantMillis)
    guard let openDay, openDay > zoneDay else { return zoneDay }
    return openDay
  }

  /// A repeated wall time takes the earlier instant; one inside a spring-forward gap takes the first instant at or after it, the transition.
  public func resolve(minuteOfDay: Int, on date: LocalDate) throws(CalendarError) -> ResolvedLocalMinute {
    guard (0..<Self.minutesPerDay).contains(minuteOfDay) else { throw .minuteOfDayOutOfRange(minuteOfDay) }
    let wall = Int64(date.daysSinceEpoch) * Self.millisPerDay + Int64(minuteOfDay) * Self.millisPerMinute
    let before = wall - offsetSeconds(at: wall - Self.millisPerDay) * 1000
    let after = wall - offsetSeconds(at: wall + Self.millisPerDay) * 1000
    let (first, second) = (min(before, after), max(before, after))
    let valid = (first == second ? [first] : [first, second]).filter { wallMillis(at: $0) == wall }
    if let matched = valid.first {
      return ResolvedLocalMinute(instantMillis: matched, date: date, minuteOfDay: minuteOfDay, resolution: valid.count > 1 ? .ambiguousEarlier : .exact)
    }
    var lower = first
    var upper = second
    while lower < upper {
      let middle = Self.floorDivide(lower + upper, 2)
      if wallMillis(at: middle) >= wall { upper = middle } else { lower = middle + 1 }
    }
    let fields = try zonedFields(at: lower)
    return ResolvedLocalMinute(instantMillis: lower, date: fields.date, minuteOfDay: fields.minuteOfDay, resolution: .gapShifted)
  }

  public func startOfDay(_ date: LocalDate) throws(CalendarError) -> Int64 {
    try resolve(minuteOfDay: 0, on: date).instantMillis
  }

  public func dayLengthMinutes(_ date: LocalDate) throws(CalendarError) -> Int {
    guard let next = date.adding(days: 1) else { throw .dateOutOfRange }
    return Int((try startOfDay(next) - startOfDay(date)) / Self.millisPerMinute)
  }

  public func clamp(_ claim: PerformedAtClaim) throws(CalendarError) -> ClampedPerformedAt {
    let upper = claim.nowMillis
    let occurrenceStart = try startOfDay(claim.occurrenceDate)
    let lower = min(max(occurrenceStart, claim.lastAckedSyncMillis ?? occurrenceStart), upper)
    let instant = min(max(claim.performedAtMillis, lower), upper)
    let outcome: PerformedAtOutcome =
      claim.performedAtMillis < lower ? .clampedToWindowStart : claim.performedAtMillis > upper ? .clampedToNow : .withinWindow
    let fields = try zonedFields(at: instant)
    return ClampedPerformedAt(
      instantMillis: instant, date: fields.date, minuteOfDay: fields.minuteOfDay, daysElapsed: fields.date.days(since: claim.occurrenceDate), outcome: outcome)
  }

  private static let minutesPerDay = 1440
  private static let secondsPerDay: Int64 = 86_400
  private static let millisPerMinute: Int64 = 60_000
  private static let millisPerDay: Int64 = 86_400_000

  /// Offsets change on whole seconds, so the lookup takes the second holding the instant and no rounding through `Date` can cross a transition.
  private func offsetSeconds(at instantMillis: Int64) -> Int64 {
    let second = Self.floorDivide(instantMillis, 1000)
    return Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(second))))
  }

  private func wallMillis(at instantMillis: Int64) -> Int64 {
    Self.wallSeconds(at: instantMillis, offsetSeconds: offsetSeconds(at: instantMillis)) * 1000
  }

  private static func wallSeconds(at instantMillis: Int64, offsetSeconds: Int64) -> Int64 {
    floorDivide(instantMillis, 1000) + offsetSeconds
  }

  private static func fields(at instantMillis: Int64, offsetSeconds: Int64) throws(CalendarError) -> ZonedFields {
    let wall = wallSeconds(at: instantMillis, offsetSeconds: offsetSeconds)
    let day = floorDivide(wall, secondsPerDay)
    let secondOfDay = Int(wall - day * secondsPerDay)
    guard let dayNumber = Int(exactly: day), let date = LocalDate(daysSinceEpoch: dayNumber) else { throw .dateOutOfRange }
    return ZonedFields(date: date, minuteOfDay: secondOfDay / 60, second: secondOfDay % 60)
  }

  private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
    let quotient = value / divisor
    return value % divisor < 0 ? quotient - 1 : quotient
  }

  private static func floorModulo(_ value: Int64, _ divisor: Int64) -> Int64 {
    value - floorDivide(value, divisor) * divisor
  }
}
