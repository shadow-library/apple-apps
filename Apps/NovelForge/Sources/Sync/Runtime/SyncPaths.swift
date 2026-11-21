import Foundation
import ShadowStore
import ShadowSyncRuntime

/// Where sync keeps its own files: `<Application Support>/<bundle id>/Sync/`, beside the vault directory and never inside it.
nonisolated struct SyncPaths: Equatable, Sendable {
  let applicationSupport: URL
  let bundleIdentifier: String
  let vaultDirectory: URL

  var location: URL { SyncLocationStore.defaultURL(applicationSupport: applicationSupport, bundleIdentifier: bundleIdentifier) }
  var firstUnlock: URL { FirstUnlockProbe.defaultURL(applicationSupport: applicationSupport, bundleIdentifier: bundleIdentifier) }
  var cloudKitIndex: URL { directory.appending(path: "cloudkit-index.json", directoryHint: .notDirectory) }
  var cloudKitEngineState: URL { directory.appending(path: "cloudkit-engine.state", directoryHint: .notDirectory) }

  private var directory: URL { location.deletingLastPathComponent() }

  static func live(fileManager: FileManager = .default, bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws(VaultOpenError) -> SyncPaths {
    guard let bundleIdentifier else { throw .locationUnavailable("the app has no bundle identifier") }
    let location = try VaultOpener.defaultLocation(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
    guard case .file(let vault) = location else { throw .locationUnavailable("the vault has no directory") }
    let support: URL
    do {
      support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    } catch {
      throw .locationUnavailable(error.localizedDescription)
    }
    return SyncPaths(applicationSupport: support, bundleIdentifier: bundleIdentifier, vaultDirectory: vault.deletingLastPathComponent())
  }
}
