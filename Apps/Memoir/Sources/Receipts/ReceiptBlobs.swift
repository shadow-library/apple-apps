import Foundation
import ShadowAppShell
import ShadowStore
import ShadowSync
import ShadowSyncRuntime

nonisolated enum ReceiptFetchError: Error {
  case blob(BlobError)
  /// Sync is not set up on this device, or no storage is attached.
  case syncOff
  /// Sync is set up but cannot run now, as while the device is locked or the account cannot be reached.
  case syncUnavailable
}

/// Where receipt images go and come from: the main store's blobs, fetched through the primary store's sync runtime when this device does not hold one.
nonisolated struct ReceiptBlobs: Sendable {
  let put: @Sendable (Data) async throws(BlobError) -> BlobID
  /// The file when this device holds the blob; nil when it has to be fetched.
  let local: @Sendable (BlobID) async throws(BlobError) -> URL?
  let fetch: @Sendable (BlobID) async throws(ReceiptFetchError) -> URL

  static func live(main: VaultStore, sync: SyncRuntimes?) -> ReceiptBlobs {
    ReceiptBlobs(
      put: { data throws(BlobError) in try await VaultBlobs(store: main).put(data) },
      local: { id throws(BlobError) in try await VaultBlobs(store: main).localURL(of: id) },
      fetch: { id throws(ReceiptFetchError) in
        guard let runtime = await MainActor.run(body: { sync?.runtime }) else {
          do throws(BlobError) {
            if let held = try await VaultBlobs(store: main).localURL(of: id) { return held }
          } catch {
            throw .blob(error)
          }
          throw .syncOff
        }
        do throws(BlobError) {
          return try await runtime.fetchBlob(id)
        } catch {
          guard case .notAttached = error else { throw .blob(error) }
          if case .detached? = await runtime.currentPhase { throw .syncOff }
          throw .syncUnavailable
        }
      })
  }
}
