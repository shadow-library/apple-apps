import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore

nonisolated enum MemoirVaultLocation: Sendable, Equatable {
  case vault(MemoirVault)
  case inMemory
}

/// A vault's stores with the projection that keeps the main store's derived rows walked to the account's day, and the clock both follow.
nonisolated struct MemoirOpenedVault: Sendable {
  let stores: MemoirStores
  let projection: MemoirReconciler
  let clock: MemoirClock
  /// The demo's vault, whose screens never read Health.
  var isDemo = false

  func refreshDay() async throws(StoreError) {
    try await projection.refresh(stores.main)
  }

  var dayTurns: ProjectionDayTurns {
    ProjectionDayTurns(store: stores.main, reconciler: projection, deviceZone: clock.deviceZone, now: clock.now, waitUntil: clock.waitUntil)
  }
}

nonisolated enum MemoirVaultOpener {
  static func defaultVault(fileManager: FileManager = .default, bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws(MemoirVaultOpenError) -> MemoirVault {
    guard let bundleIdentifier else { throw .locationUnavailable("the app has no bundle identifier") }
    let support: URL
    do {
      support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    } catch {
      throw .locationUnavailable(error.localizedDescription)
    }
    do {
      return try MemoirVault(directory: support.appending(path: bundleIdentifier).appending(path: "Vaults", directoryHint: .isDirectory))
    } catch {
      throw .locationUnavailable(error.localizedDescription)
    }
  }

  static var isHostedByTests: Bool { VaultDirectory.isHostedByTests }

  /// The app's own vault, or in-memory stores while XCTest hosts the app.
  static func appLocation() throws(MemoirVaultOpenError) -> MemoirVaultLocation {
    guard !isHostedByTests else { return .inMemory }
    return .vault(try defaultVault())
  }

  /// The projection's fingerprint must change with every build, which only the build number does.
  static func buildVersion(of infoDictionary: [String: Any]? = Bundle.main.infoDictionary) throws(MemoirVaultOpenError) -> String {
    guard let version = infoDictionary?["CFBundleVersion"] as? String, !version.isEmpty else { throw .buildVersionUnavailable }
    return version
  }

  @concurrent
  static func open(_ location: MemoirVaultLocation, appVersion: String, clock: MemoirClock = .device) async throws(MemoirVaultOpenError) -> MemoirOpenedVault {
    do {
      let projection = try MemoirReconciler(appVersion: appVersion, now: clock.now, deviceZone: clock.deviceZone)
      let stores =
        switch location {
        case .vault(let vault): try MemoirStores.open(in: vault, wallClock: clock.now, projection: projection)
        case .inMemory: try MemoirStores.openInMemory(wallClock: clock.now, projection: projection)
        }
      let opened = MemoirOpenedVault(stores: stores, projection: projection, clock: clock)
      try await opened.refreshDay()
      return opened
    } catch {
      throw .openFailed(error.localizedDescription)
    }
  }
}
