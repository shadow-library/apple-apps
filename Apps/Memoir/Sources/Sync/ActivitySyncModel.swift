import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// The owner's Activity-through-iCloud setting: off by default, kept in the main store so every device follows it, and applied to sync at once. While
/// Body is off it stays off (`ModuleChanges` keeps it so) and is not offered.
@MainActor
@Observable
final class ActivitySyncModel {
  enum State: Equatable {
    case loading
    case loaded(isOn: Bool)
    case bodyOff
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
      let isOn = try await main.read { transaction -> Bool? in
        guard try MemoirModules.selection(in: transaction).contains(.body) else { return nil }
        return try HealthSettings.isActivityOnICloud(in: transaction)
      }
      state = isOn.map { .loaded(isOn: $0) } ?? .bodyOff
    } catch {
      state = .unreadable(PresentedError(error))
    }
  }

  /// Turning it on is refused, writing nothing, once Body is off as the write reads it. Turning it off stops activity syncing through iCloud and leaves
  /// every activity record on this device, out of its backups.
  func set(_ isOn: Bool) async {
    guard case .loaded(let current) = state, current != isOn, !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    let main = main
    do {
      let written = try await main.write { transaction -> Bool in
        if isOn, try !MemoirModules.selection(in: ReadTransaction(database: transaction.database, registry: main.registry)).contains(.body) { return false }
        try HealthSettings.setActivityOnICloud(isOn, in: &transaction)
        return true
      }
      guard written else {
        failure = nil
        state = .bodyOff
        return
      }
    } catch {
      failure = PresentedError(error)
      return
    }
    failure = nil
    state = .loaded(isOn: isOn)
    await sync.reroute()
  }
}
