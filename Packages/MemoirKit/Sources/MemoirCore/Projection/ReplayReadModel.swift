import Foundation
import ShadowCore
import ShadowStore

/// A screen's read of the replay projection: it reads the `mm_derived_*` rows through `MemoirDerived` and the records they name, and never runs replay.
/// Every model is as of the view's open day; `changesOn` is the next day its contents turn with no write, when `ProjectionDayTurns` refreshes the view.
public protocol ReplayReadModel: Sendable, Equatable {
  associatedtype Query: Sendable

  static func load(_ query: Query, in transaction: ReadTransaction) throws(StoreError) -> Self
}

extension VaultStore {
  public func load<Model: ReplayReadModel>(_: Model.Type, _ query: Model.Query) async throws(StoreError) -> Model {
    try await read { transaction in try Model.load(query, in: transaction) }
  }

  /// Emits the model, then again whenever a commit changes it: a command or record written here or merged from another device, or the projection's
  /// refresh when the day turns.
  public func observe<Model: ReplayReadModel>(_: Model.Type, _ query: Model.Query) -> AsyncThrowingStream<Model, any Error> {
    observeReads { transaction in try Model.load(query, in: transaction) }
  }
}

/// Refreshes the projection each time the account's day turns, so the view walks to the new day, its missed occurrences are recorded, and every observed
/// read model re-emits. The turn is the next midnight of the clock `AccountZone` gives after each refresh, so a staged zone takes over at its first day.
/// `run()` refreshes as it starts; the app restarts it when the system clock or the device's zone changes significantly, since a wait already under way
/// does not notice. The reconciler should take its horizon from the same zone (`MemoirReconciler(appVersion:now:deviceZone:)`).
public struct ProjectionDayTurns: Sendable {
  private let store: VaultStore
  private let reconciler: MemoirReconciler
  private let deviceZone: @Sendable () -> TimeZone
  private let now: @Sendable () -> Date
  private let waitUntil: @Sendable (Date) async throws -> Void

  /// `deviceZone` is the app's `{ TimeZone.current }`, which governs only before any zone is set.
  public init(
    store: VaultStore, reconciler: MemoirReconciler, deviceZone: @escaping @Sendable () -> TimeZone, now: @escaping @Sendable () -> Date = { Date() },
    waitUntil: @escaping @Sendable (Date) async throws -> Void = ProjectionDayTurns.sleep(until:)
  ) {
    self.store = store
    self.reconciler = reconciler
    self.deviceZone = deviceZone
    self.now = now
    self.waitUntil = waitUntil
  }

  /// The start of the next day after `instant` in the clock in force then.
  public func nextTurn(after instant: Date, zone: AccountZone) throws(CalendarError) -> Date {
    let clock = zone.clock(at: instant, device: deviceZone())
    guard let tomorrow = try clock.localDate(at: AccountZone.millis(instant)).adding(days: 1) else { throw .dateOutOfRange }
    return Date(timeIntervalSince1970: Double(try clock.startOfDay(tomorrow)) / 1000)
  }

  /// Refreshes once now, then at every turn of the day until the task is cancelled, reading the zone again after each refresh.
  public func run() async throws {
    try await reconciler.refresh(store)
    while !Task.isCancelled {
      let zone = try await AccountZone.load(from: store)
      try await waitUntil(try nextTurn(after: now(), zone: zone))
      try Task.checkCancellation()
      try await reconciler.refresh(store)
    }
  }

  /// A device asleep past the turn wakes late rather than early: the continuous clock counts the time asleep.
  public static func sleep(until date: Date) async throws {
    let interval = date.timeIntervalSinceNow
    guard interval > 0 else { return }
    try await Task.sleep(for: .milliseconds(Int64((interval * 1000).rounded(.up))), clock: .continuous)
  }
}
