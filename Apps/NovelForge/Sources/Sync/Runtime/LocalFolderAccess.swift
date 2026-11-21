import Foundation
import OSLog
import ShadowSync
import ShadowSyncRuntime
import Synchronization

/// Resolves a local sync folder from its security-scoped bookmark and keeps access to it for the life of the process, once per folder; a folder saved
/// without a bookmark is used by its path, which works only outside the sandbox or inside the app's own container.
nonisolated final class LocalFolderAccess: Sendable {
  private static let logger = Logger(subsystem: SyncWiring.app, category: "sync")
  #if os(macOS)
    private static let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
  #else
    private static let options: URL.BookmarkResolutionOptions = []
  #endif

  private let opened = Mutex<[String: URL]>([:])

  init() {}

  func root(for settings: SyncLocalFolderSettings) throws(StorageError) -> URL {
    guard let bookmark = settings.bookmark else { return settings.url }
    let resolved: Result<URL, StorageError> = opened.withLock { opened in
      if let url = opened[settings.path] { return .success(url) }
      var isStale = false
      let url: URL
      do {
        url = try URL(resolvingBookmarkData: bookmark, options: Self.options, relativeTo: nil, bookmarkDataIsStale: &isStale)
      } catch {
        return .failure(.unavailable("The sync folder can no longer be found: \(error.localizedDescription)"))
      }
      if isStale { Self.logger.notice("The sync folder's bookmark is stale; choose the folder again to refresh it") }
      if !url.startAccessingSecurityScopedResource() { Self.logger.notice("The sync folder needs no security scope") }
      opened[settings.path] = url
      return .success(url)
    }
    return try resolved.get()
  }
}
