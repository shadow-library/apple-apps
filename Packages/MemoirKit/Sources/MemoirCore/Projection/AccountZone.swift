import Foundation
import ShadowStore

/// The account's zone as the projection's open day holds it: the zone in force on that day and a change staged for the next day the walk opens. It is the
/// one source of the clock the app stamps commands, the horizon and the day turns with, so they follow the account's zone rather than the device's.
public struct AccountZone: Sendable, Hashable {
  public static let unset = AccountZone(inForce: nil, openDay: nil, lastRecordedOffsetMinutes: nil, staged: nil)

  /// A staged change, with the offset it was issued under: until the walk promotes it, the day is measured from that offset.
  public struct Staged: Sendable, Hashable {
    public let identifier: String
    public let issuedUnderOffsetMinutes: Int

    public init(identifier: String, issuedUnderOffsetMinutes: Int) {
      self.identifier = identifier
      self.issuedUnderOffsetMinutes = issuedUnderOffsetMinutes
    }
  }

  /// Where the clock in force came from, so the app can say when this device does not know the account's zone.
  public enum Source: Sendable, Hashable {
    case account(String)
    case staged(String)
    case deviceBeforeAnyZone
    /// This device's zone data lacks the zone; the clock keeps `fallbackOffsetMinutes`, or is the device's when no offset was recorded.
    case unknownZone(identifier: String, fallbackOffsetMinutes: Int?)
  }

  public struct Resolved: Sendable {
    public let clock: IssueClock
    public let source: Source
  }

  /// Nil before any zone is set.
  public let inForce: String?
  public let openDay: LocalDate?
  /// The offset the latest command recorded, which stands in for a zone in force this device does not know.
  public let lastRecordedOffsetMinutes: Int?
  public let staged: Staged?

  public init(inForce: String?, openDay: LocalDate?, lastRecordedOffsetMinutes: Int?, staged: Staged?) {
    self.inForce = inForce
    self.openDay = openDay
    self.lastRecordedOffsetMinutes = lastRecordedOffsetMinutes
    self.staged = staged
  }

  init(_ state: ReplayState) {
    self.init(
      inForce: state.openDay.flatMap(state.settings.timeZone(on:)), openDay: state.openDay, lastRecordedOffsetMinutes: state.latestUtcOffsetMinutes,
      staged: state.settings.pendingTimeZone.map { Staged(identifier: $0.value, issuedUnderOffsetMinutes: $0.utcOffsetMinutes) })
  }

  /// The first day the staged zone can govern: the day after the open day, which the walk opens under it.
  public var stagedFirstDay: LocalDate? {
    guard staged != nil else { return nil }
    return openDay?.adding(days: 1)
  }

  /// The clock in force at the instant: the staged zone once the open day has passed as the zone it replaces measures it, else the zone in force, else
  /// `device` before any zone is set. A zone this device's data lacks keeps a fixed offset: the one the staged change was issued under, the best record
  /// of it, or the one the latest command recorded for the zone in force.
  public func resolve(at instantMillis: Int64, device: TimeZone) -> Resolved {
    if let staged, let openDay, let reached = ReplayState.localDate(instantMillis, offset: staged.issuedUnderOffsetMinutes), reached > openDay {
      return Self.resolve(staged.identifier, fallback: staged.issuedUnderOffsetMinutes, source: .staged(staged.identifier), device: device)
    }
    guard let inForce else { return Resolved(clock: IssueClock(timeZone: device), source: .deviceBeforeAnyZone) }
    return Self.resolve(inForce, fallback: lastRecordedOffsetMinutes, source: .account(inForce), device: device)
  }

  public func clock(at instantMillis: Int64, device: TimeZone) -> IssueClock {
    resolve(at: instantMillis, device: device).clock
  }

  public func clock(at instant: Date, device: TimeZone) -> IssueClock {
    clock(at: Self.millis(instant), device: device)
  }

  public func source(at instant: Date, device: TimeZone) -> Source {
    resolve(at: Self.millis(instant), device: device).source
  }

  private static func resolve(_ identifier: String, fallback: Int?, source: Source, device: TimeZone) -> Resolved {
    if let clock = IssueClock(zoneIdentifier: identifier) { return Resolved(clock: clock, source: source) }
    let fixed = fallback.flatMap(IssueClock.init(fixedOffsetMinutes:))
    return Resolved(clock: fixed ?? IssueClock(timeZone: device), source: .unknownZone(identifier: identifier, fallbackOffsetMinutes: fixed == nil ? nil : fallback))
  }

  /// The projection's horizon at the instant: the account's day in the clock in force.
  public func horizon(at instant: Date, device: TimeZone) -> IssueStamp? {
    let millis = Self.millis(instant)
    return try? clock(at: millis, device: device).stamp(at: millis)
  }

  public static func load(in transaction: ReadTransaction) throws(StoreError) -> AccountZone {
    try MemoirDerived.hero(in: transaction)?.zone ?? .unset
  }

  public static func load(from store: VaultStore) async throws(StoreError) -> AccountZone {
    try await store.read { transaction in try load(in: transaction) }
  }

  static func millis(_ instant: Date) -> Int64 {
    Int64((instant.timeIntervalSince1970 * 1000).rounded(.down))
  }
}
