import Foundation
import MemoirCore

/// The app's one notion of now: the trusted wall clock the stores stamp changes with, the device's zone (which governs only before the account has a
/// zone) and the wait the day turns sleep with.
nonisolated struct MemoirClock: Sendable {
  static let device = MemoirClock(now: { Date() })

  let now: @Sendable () -> Date
  let deviceZone: @Sendable () -> TimeZone
  let waitUntil: @Sendable (Date) async throws -> Void

  init(
    now: @escaping @Sendable () -> Date, deviceZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
    waitUntil: (@Sendable (Date) async throws -> Void)? = nil
  ) {
    self.now = now
    self.deviceZone = deviceZone
    self.waitUntil = waitUntil ?? { date in try await Self.sleep(until: date, now: now) }
  }

  /// The clock in force now and where it came from.
  func resolve(_ zone: AccountZone) -> AccountZone.Resolved {
    zone.resolve(at: Self.millis(now()), device: deviceZone())
  }

  func issuer(in zone: AccountZone) -> CommandIssuer {
    CommandIssuer(clock: resolve(zone).clock, wallClock: now)
  }

  /// Resolves the issuer from the account's zone as each command's main-store write sees it.
  var issuerSource: CommandIssuerSource {
    CommandIssuerSource { [self] transaction in issuer(in: try AccountZone.load(in: transaction)) }
  }

  /// The account's day now: the date in the clock in force, or the projection's open day when a backward zone change left it ahead, as replay takes
  /// `max(issuedOn, open day)`.
  func today(in zone: AccountZone) throws(CalendarError) -> MemoirToday {
    let millis = Self.millis(now())
    let resolved = zone.resolve(at: millis, device: deviceZone())
    let date = try resolved.clock.localDate(at: millis)
    return MemoirToday(date: max(date, zone.openDay ?? date), source: resolved.source)
  }

  /// The deadline is in the trusted clock, which can differ from the device's, so the interval is measured from the trusted now. The continuous clock
  /// counts time asleep, so a device asleep past the deadline wakes late rather than early.
  static func sleep(until date: Date, now: @Sendable () -> Date) async throws {
    let interval = date.timeIntervalSince(now())
    guard interval > 0 else { return }
    try await Task.sleep(for: .milliseconds(Int64((interval * 1000).rounded(.up))), clock: .continuous)
  }

  static func millis(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
  }
}

/// The account's day as a screen shows it, with where its clock came from so a screen can say when this device does not know the account's zone.
nonisolated struct MemoirToday: Sendable, Hashable {
  let date: LocalDate
  let source: AccountZone.Source
}
