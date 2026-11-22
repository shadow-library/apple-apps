import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowStore

nonisolated enum VaultOpener {
  static func defaultLocation(fileManager: FileManager = .default, bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws(VaultOpenError) -> StoreLocation {
    .file(try VaultDirectory.default(fileManager: fileManager, bundleIdentifier: bundleIdentifier).appending(path: "vault.sqlite"))
  }

  /// The app's own vault, or an in-memory one while XCTest hosts the app.
  static func appLocation() throws(VaultOpenError) -> StoreLocation {
    guard !VaultDirectory.isHostedByTests else { return .inMemory }
    return try defaultLocation()
  }

  /// `wallClock` stamps the store's changes; sync needs `SyncEngine.wallClock(preferring:)` of the trusted clock it is given.
  @concurrent
  static func open(_ location: StoreLocation, wallClock: @escaping @Sendable () -> Date = { Date() }) async throws(VaultOpenError) -> VaultStore {
    do {
      switch location {
      case .file(let url): return try NovelForgeStore.open(at: url, wallClock: wallClock)
      case .inMemory: return try NovelForgeStore.openInMemory(wallClock: wallClock)
      }
    } catch {
      throw .openFailed(error.localizedDescription)
    }
  }
}
