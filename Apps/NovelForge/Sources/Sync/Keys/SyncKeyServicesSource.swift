import Foundation
import ShadowSync
import ShadowSyncRuntime

/// The key services of the runtime's attached vault, fetched once and fetched again when a call finds them stale: after a move, a disconnect and
/// reconnect or an account that came back, the same vault is served by a new attachment.
@MainActor
final class SyncKeyServicesSource {
  let runtime: SyncRuntime
  private var access: SyncKeyAccess?

  init(runtime: SyncRuntime) {
    self.runtime = runtime
  }

  func current() async throws(SyncKeysError) -> SyncKeyAccess {
    if let access { return access }
    do {
      let fetched = try await runtime.keyServices()
      access = fetched
      return fetched
    } catch {
      throw .services(error)
    }
  }

  func reload() async throws(SyncKeysError) -> SyncKeyAccess {
    access = nil
    return try await current()
  }

  /// Runs `body`, and once more on freshly fetched services when the first ones were stale; a vault other than `vault` stops it with `vaultChanged`.
  func perform<T>(for vault: VaultID, _ body: (SyncKeyAccess) async throws(SyncKeysError) -> T) async throws(SyncKeysError) -> T {
    let first = try await current()
    guard first.vault == vault else { throw .vaultChanged }
    do {
      return try await body(first)
    } catch {
      guard error.isStaleAccess else { throw error }
      let fresh = try await reload()
      guard fresh.vault == vault else { throw .vaultChanged }
      return try await body(fresh)
    }
  }
}
