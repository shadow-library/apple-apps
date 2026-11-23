import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowSyncRuntime

/// "Restore from an export" (the owner's decision: only into an empty vault, never a merge or a replacement). It is offered while every store is empty
/// and sync has settled: known to be off (no location attached and none attached automatically), or up to date with storage that brought nothing, so the
/// storage holds none of this vault's data; before sync has looked, nothing is offered. Picking an archive reads and checks all of it and shows what it
/// holds; nothing is written before the owner confirms, and the restore checks both again then. Once it is in, onboarding gives way to the app on its own.
/// A restore that committed some stores and not the main one is offered only an erase, after which the vault opens empty and can be restored again.
@MainActor
@Observable
final class RestoreModel {
  enum Stage: Equatable {
    case idle
    case reading
    case confirming(MemoirRestorePreview)
    case restoring
    case failed(PresentedError)
  }

  private(set) var stage = Stage.idle
  private(set) var isEmpty = false
  private(set) var isUnfinished = false
  private(set) var isSyncSettled = false
  private(set) var isErasing = false
  private(set) var eraseFailure: PresentedError?
  var isPicking = false
  private var hasClearedStaleMarker = false
  /// Asked when the offer is read and again when the owner confirms; the view sets it from this window's `SyncRuntimes`.
  var syncSettled: @MainActor () async -> Bool = { false }

  private let stores: MemoirStores
  private let restores: MemoirRestores

  init(context: MemoirScreenContext, restores: MemoirRestores = .live) {
    stores = context.stores
    self.restores = restores
  }

  var isOffered: Bool { isEmpty && isSyncSettled }

  var isPresentingConfirmation: Bool {
    switch stage {
    case .confirming, .restoring, .failed: true
    case .idle, .reading: false
    }
  }

  /// `.off` is also the status before the primary runtime has looked at its location, so it counts only with the phase that says none is attached.
  nonisolated static func syncAllows(_ status: SyncStatus, phase: SyncPhase?) -> Bool {
    switch status {
    case .upToDate: true
    case .off: phase == .detached
    case .syncing, .attentionNeeded: false
    }
  }

  /// Until the primary runtime has finished its launch run, or with no runtime at all, nothing says the storage is empty.
  static func settled(_ sync: SyncRuntimes?) async -> Bool {
    guard let sync, sync.hasStarted, let runtime = sync.runtime else { return false }
    return syncAllows(sync.status, phase: await runtime.currentPhase)
  }

  /// Reads whether the vault is still empty or half restored, and whether sync has settled; a read that fails offers nothing. The first read clears a
  /// stale marker, before anything is offered and so before any restore can start.
  func refresh() async {
    if !hasClearedStaleMarker {
      hasClearedStaleMarker = true
      try? await MemoirRestore.clearStaleMarker(stores)
    }
    isSyncSettled = await syncSettled()
    isEmpty = (try? await MemoirRestore.isEmpty(stores)) == true
    isUnfinished = (try? await MemoirRestore.isUnfinished(stores)) == true
  }

  /// Erases the half-restored vault through the vault deletion, once a fresh read confirms it is half restored; the vault then opens again empty, with
  /// this model gone.
  func eraseUnfinished(_ erase: @MainActor () async throws(VaultDeletionError) -> Void) async {
    guard !isErasing, stage != .restoring else { return }
    isErasing = true
    defer { isErasing = false }
    eraseFailure = nil
    guard (try? await MemoirRestore.isUnfinished(stores)) == true else { return await refresh() }
    do {
      try await erase()
    } catch {
      eraseFailure = DataCopy.deletionFailure(error)
    }
    await refresh()
  }

  func picked(_ result: Result<URL, any Error>) async {
    guard case .success(let url) = result else { return }
    guard stage == .idle || isFailed else { return }
    stage = .reading
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      stage = .confirming(try await MemoirImporter.read(url, into: restores))
    } catch {
      stage = .failed(DataCopy.importFailure(error))
    }
  }

  /// True once the vault holds the export; the files read from the archive go either way.
  @discardableResult
  func confirm() async -> Bool {
    guard case .confirming(let preview) = stage else { return false }
    stage = .restoring
    defer { restores.clear() }
    guard await syncSettled() else {
      stage = .failed(DataCopy.importFailure(.syncUnsettled))
      return false
    }
    do {
      try await MemoirRestore.restore(preview.contents, into: stores)
      stage = .idle
      await refresh()
      return true
    } catch {
      stage = .failed(DataCopy.restoreFailure(error))
      await refresh()
      return false
    }
  }

  func cancel() {
    guard stage != .restoring else { return }
    restores.clear()
    stage = .idle
  }

  private var isFailed: Bool {
    guard case .failed = stage else { return false }
    return true
  }
}
