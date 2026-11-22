import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// The owner's Activity-through-iCloud setting: off by default, kept in the main store so every device follows it, and applied to sync at once.
@MainActor
@Observable
final class ActivitySyncModel {
  enum State: Equatable {
    case loading
    case loaded(isOn: Bool)
    case unreadable(PresentedError)
  }

  private(set) var state = State.loading
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  let main: VaultStore
  let sync: SyncRuntimes

  init(main: VaultStore, sync: SyncRuntimes) {
    self.main = main
    self.sync = sync
  }

  var isOn: Bool {
    guard case .loaded(let isOn) = state else { return false }
    return isOn
  }

  /// Also after a sync, which may bring the setting from another device.
  func load() async {
    do {
      state = .loaded(isOn: try await main.read { transaction in try HealthSettings.isActivityOnICloud(in: transaction) })
    } catch {
      state = .unreadable(PresentedError(error))
    }
  }

  /// Turning it off stops activity syncing through iCloud and leaves every activity record on this device, out of its backups.
  func set(_ isOn: Bool) async {
    guard case .loaded(let current) = state, current != isOn, !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      _ = try await main.write { transaction in try HealthSettings.setActivityOnICloud(isOn, in: &transaction) }
    } catch {
      failure = PresentedError(error)
      return
    }
    failure = nil
    state = .loaded(isOn: isOn)
    await sync.reroute()
  }
}
