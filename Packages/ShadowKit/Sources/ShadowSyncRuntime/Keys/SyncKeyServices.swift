import Foundation
import ShadowStore
import ShadowSync
import Synchronization

/// The key services of one attached vault, shared by every `SyncAttachment` that `SyncStartup` hands out for it, so calls on one vault are serialised
/// by one `RecoverySetup` and replays are refused by one `KeyExchangeCoordinator`.
final class SyncKeyServices: Sendable {
  private struct State {
    var setup: (store: VaultStore, setup: RecoverySetup)?
    var exchange: KeyExchangeCoordinator?
  }

  private let state = Mutex(State())

  func recoverySetup(store: VaultStore, provider: any StorageProvider, ring: KeyRing, wallClock: @escaping @Sendable () -> Date) -> RecoverySetup {
    state.withLock { state in
      if let existing = state.setup, existing.store === store { return existing.setup }
      let setup = RecoverySetup(store: store, provider: provider, ring: ring, wallClock: wallClock)
      state.setup = (store, setup)
      return setup
    }
  }

  func keyExchange(provider: any StorageProvider, ring: KeyRing) -> KeyExchangeCoordinator {
    state.withLock { state in
      if let exchange = state.exchange { return exchange }
      let exchange = KeyExchangeCoordinator(provider: provider, ring: ring)
      state.exchange = exchange
      return exchange
    }
  }
}
