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

  @concurrent
  static func open(_ location: StoreLocation) async throws(VaultOpenError) -> VaultStore {
    do {
      switch location {
      case .file(let url): return try NovelForgeStore.open(at: url)
      case .inMemory: return try NovelForgeStore.openInMemory()
      }
    } catch {
      throw .openFailed(error.localizedDescription)
    }
  }
}
