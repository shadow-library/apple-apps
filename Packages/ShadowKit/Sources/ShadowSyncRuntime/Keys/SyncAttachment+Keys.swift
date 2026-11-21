import Foundation
import ShadowStore
import ShadowSync

extension SyncAttachment {
  /// The vault's one `RecoverySetup` for `store`; `wallClock` applies only when this call creates it.
  public func recoverySetup(store: VaultStore, wallClock: @escaping @Sendable () -> Date = { Date() }) -> RecoverySetup {
    keyServices.recoverySetup(store: store, provider: provider, ring: ring, wallClock: wallClock)
  }

  public var phraseRecovery: PhraseRecovery {
    PhraseRecovery(provider: provider, ring: ring)
  }

  public var keyExchange: KeyExchangeCoordinator {
    keyServices.keyExchange(provider: provider, ring: ring)
  }
}
