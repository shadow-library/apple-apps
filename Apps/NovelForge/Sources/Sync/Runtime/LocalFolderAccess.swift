import Foundation
import OSLog
import ShadowSync
import ShadowSyncRuntime
import Synchronization

/// Resolves a local sync folder from its security-scoped bookmark and keeps access to it for the life of the process, once per folder; a folder saved
/// without a bookmark is used by its path, which works only outside the sandbox or inside the app's own container.
nonisolated final class LocalFolderAccess: Sendable {
  struct Resolved: Equatable, Sendable {
    let url: URL
    /// The folder's settings with a fresh bookmark, when the saved one resolved but was stale.
    let refreshed: SyncLocalFolderSettings?
  }

  private static let logger = Logger(subsystem: SyncWiring.app, category: "sync")
  #if os(macOS)
    private static let resolution: URL.BookmarkResolutionOptions = [.withSecurityScope]
    private static let creation: URL.BookmarkCreationOptions = [.withSecurityScope]
  #else
    private static let resolution: URL.BookmarkResolutionOptions = []
    private static let creation: URL.BookmarkCreationOptions = []
  #endif

  private let opened = Mutex<[String: URL]>([:])

  init() {}

  /// The settings for a folder the user picked: its security-scoped bookmark is made while the picker's access lasts.
  static func settings(forPicked url: URL) throws(StorageError) -> SyncLocalFolderSettings {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      return SyncLocalFolderSettings(url: url, bookmark: try url.bookmarkData(options: creation, includingResourceValuesForKeys: nil, relativeTo: nil))
    } catch {
      throw .unavailable("The folder cannot be remembered: \(error.localizedDescription)")
    }
  }

  func root(for settings: SyncLocalFolderSettings) throws(StorageError) -> URL {
    try resolve(settings).url
  }

  func resolve(_ settings: SyncLocalFolderSettings) throws(StorageError) -> Resolved {
    guard let bookmark = settings.bookmark else { return Resolved(url: settings.url, refreshed: nil) }
    let resolved: Result<Resolved, StorageError> = opened.withLock { opened in
      if let url = opened[settings.path] { return .success(Resolved(url: url, refreshed: nil)) }
      var isStale = false
      let url: URL
      do {
        url = try URL(resolvingBookmarkData: bookmark, options: Self.resolution, relativeTo: nil, bookmarkDataIsStale: &isStale)
      } catch {
        return .failure(.unavailable("The sync folder can no longer be found: \(error.localizedDescription)"))
      }
      if !url.startAccessingSecurityScopedResource() { Self.logger.notice("The sync folder needs no security scope") }
      opened[settings.path] = url
      guard isStale else { return .success(Resolved(url: url, refreshed: nil)) }
      do {
        let fresh = try url.bookmarkData(options: Self.creation, includingResourceValuesForKeys: nil, relativeTo: nil)
        let refreshed = SyncLocalFolderSettings(url: url, bookmark: fresh)
        opened[refreshed.path] = url
        return .success(Resolved(url: url, refreshed: refreshed))
      } catch {
        Self.logger.notice("The sync folder's bookmark is stale and could not be renewed; choose the folder again to refresh it")
        return .success(Resolved(url: url, refreshed: nil))
      }
    }
    return try resolved.get()
  }
}
