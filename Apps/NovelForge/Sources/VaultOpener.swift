import Foundation
import NovelForgeCore
import ShadowStore

nonisolated enum VaultOpener {
  static let vaultName = "Default"

  static func defaultLocation(fileManager: FileManager = .default, bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws(VaultOpenError) -> StoreLocation {
    guard let bundleIdentifier else { throw .locationUnavailable("the app has no bundle identifier") }
    do {
      let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      return .file(support.appending(path: bundleIdentifier).appending(path: "Vaults").appending(path: vaultName).appending(path: "vault.sqlite"))
    } catch {
      throw .locationUnavailable(error.localizedDescription)
    }
  }

  static var isHostedByTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

  /// The app's own vault, or an in-memory one while XCTest hosts the app.
  static func appLocation() throws(VaultOpenError) -> StoreLocation {
    guard !isHostedByTests else { return .inMemory }
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
