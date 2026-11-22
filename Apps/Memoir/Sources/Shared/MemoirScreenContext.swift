import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore

/// What every Memoir screen is given: the vault's stores to read, the writer to change them through, and the account's day.
nonisolated struct MemoirScreenContext: Sendable {
  let stores: MemoirStores
  let writer: MemoirWriter
  let isDemo: Bool

  init(stores: MemoirStores, clock: MemoirClock, isDemo: Bool = false) {
    self.stores = stores
    writer = MemoirWriter(stores: stores, clock: clock)
    self.isDemo = isDemo
  }

  init(_ opened: MemoirOpenedVault) {
    self.init(stores: opened.stores, clock: opened.clock, isDemo: opened.isDemo)
  }

  /// In-memory stores with the projection, for previews.
  static func inMemory(clock: MemoirClock = .device) throws -> MemoirScreenContext {
    let projection = try MemoirReconciler(appVersion: "preview", now: clock.now, deviceZone: clock.deviceZone)
    return MemoirScreenContext(stores: try MemoirStores.openInMemory(wallClock: clock.now, projection: projection), clock: clock)
  }

  var clock: MemoirClock { writer.clock }

  /// Where this device's own choices about the vault's screens are kept: the demo keeps its in the demo's suite, never in the owner's defaults.
  var defaults: UserDefaults { isDemo ? DemoDefaults.suite(for: .memoir) : .standard }

  func today() async throws(MemoirWriteError) -> MemoirToday {
    let zone = try await writer.accountZone()
    do throws(CalendarError) {
      return try clock.today(in: zone)
    } catch {
      throw .clock(error)
    }
  }

  /// Emits the account's day, then again after each commit that changes it, the day turns' refresh included.
  func observeToday() -> AsyncThrowingStream<MemoirToday, any Error> {
    let clock = clock
    return stores.main.observeReads { transaction in try clock.today(in: try AccountZone.load(in: transaction)) }
  }
}
