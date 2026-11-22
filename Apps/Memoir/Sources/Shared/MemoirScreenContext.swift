import Foundation
import MemoirCore
import ShadowStore

/// What every Memoir screen is given: the vault's stores to read, the writer to change them through, and the account's day.
nonisolated struct MemoirScreenContext: Sendable {
  let stores: MemoirStores
  let writer: MemoirWriter

  init(stores: MemoirStores, clock: MemoirClock) {
    self.stores = stores
    writer = MemoirWriter(stores: stores, clock: clock)
  }

  init(_ opened: MemoirOpenedVault) {
    self.init(stores: opened.stores, clock: opened.clock)
  }

  /// In-memory stores with the projection, for previews.
  static func inMemory(clock: MemoirClock = .device) throws -> MemoirScreenContext {
    let projection = try MemoirReconciler(appVersion: "preview", now: clock.now, deviceZone: clock.deviceZone)
    return MemoirScreenContext(stores: try MemoirStores.openInMemory(wallClock: clock.now, projection: projection), clock: clock)
  }

  var clock: MemoirClock { writer.clock }

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
