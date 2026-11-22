import Foundation
import ShadowSyncRuntime

/// Where an app keeps its vault: `<Application Support>/<bundle id>/Vaults/Default/`, with sync's own files beside it (`SyncPaths`).
public nonisolated enum VaultDirectory {
  public static let defaultName = "Default"

  public static func `default`(fileManager: FileManager = .default, bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws(VaultOpenError) -> URL {
    guard let bundleIdentifier else { throw .locationUnavailable("the app has no bundle identifier") }
    do {
      let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      return support.appending(path: bundleIdentifier).appending(path: "Vaults").appending(path: defaultName)
    } catch {
      throw .locationUnavailable(error.localizedDescription)
    }
  }

  public static var isHostedByTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

  /// A Mac has no protection before the first unlock, so an open failure there is always a failure.
  public static func hasUnlockedSinceBoot() async -> Bool {
    #if os(macOS)
      return true
    #else
      guard let paths = try? SyncPaths.live() else { return true }
      return FirstUnlockProbe(url: paths.firstUnlock).hasUnlockedSinceBoot()
    #endif
  }
}
