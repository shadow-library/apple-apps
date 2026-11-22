import NovelForgeCore
import ShadowAppShell
import ShadowStore
import SwiftUI

/// One `RetrievalUpkeep` per open vault, shared by every window, which keeps the vault's retrieval index level with its records in the background. On iOS it
/// stops while the app is in the background, where the system suspends the process mid-batch anyway, and starts again on return, catching every novel up;
/// on the Mac it keeps running. Starts and stops are applied one at a time, in the order the phases arrived.
@MainActor
final class RetrievalRuntimes {
  #if os(iOS)
    nonisolated static let stopsInBackground = true
  #else
    nonisolated static let stopsInBackground = false
  #endif

  private let stopsInBackground: Bool
  private let debounce: Duration
  private var current: (store: ObjectIdentifier, upkeep: RetrievalUpkeep)?
  private(set) var inBackground = false
  private var changing: Task<Void, Never>?

  init(stopsInBackground: Bool = RetrievalRuntimes.stopsInBackground, debounce: Duration = RetrievalUpkeep.defaultDebounce) {
    self.stopsInBackground = stopsInBackground
    self.debounce = debounce
  }

  var upkeep: RetrievalUpkeep? { current?.upkeep }

  /// The vault whose upkeep runs.
  var launched: ObjectIdentifier? { current?.store }

  /// Once per vault: a vault opened in place of another stops the other's upkeep first.
  func launch(_ store: VaultStore?, embedders: any EmbedderProvider) async {
    guard let store, current?.store != ObjectIdentifier(store) else { return }
    let replaced = current?.upkeep
    current = (ObjectIdentifier(store), RetrievalUpkeep(store: store, embedders: embedders, debounce: debounce))
    await apply(stopping: replaced)
  }

  /// Stops the upkeep for good, as before its vault closes.
  func shutDown() async {
    let replaced = current?.upkeep
    current = nil
    await apply(stopping: replaced)
  }

  func phaseChanged(_ phase: ScenePhase) async {
    switch phase {
    case .background: inBackground = true
    case .active: inBackground = false
    default: return
    }
    await apply(stopping: nil)
  }

  private func apply(stopping replaced: RetrievalUpkeep?) async {
    let (runs, upkeep, before) = (!(stopsInBackground && inBackground), current?.upkeep, changing)
    let task = Task {
      await before?.value
      await replaced?.stop()
      if runs { await upkeep?.start() } else { await upkeep?.stop() }
    }
    changing = task
    await task.value
  }
}
