import Foundation
import ShadowCore
import ShadowSync

public enum SyncAccountStatus: Sendable, Equatable {
  /// The binding is nil when the provider cannot tell accounts apart (a local folder, S3).
  case available(SyncAccountBinding?)
  case noAccount
  case temporarilyUnavailable
}

public enum VaultChoice: Sendable, Equatable {
  case create
  case join(VaultID)
}

public struct SyncStartupEnvironment: Sendable {
  public var locationStore: SyncLocationStore
  public var stores: SyncSecureStores
  /// The location attached without asking (iCloud) when none is saved; nil when every location needs an explicit choice or sync is turned off.
  public var automatic: SyncProviderSettings?
  /// The driver keeps the attached location's provider while it stays attached, and the latest other one while its settings stay the same.
  public var provider: @Sendable (SyncProviderSettings) throws(StorageError) -> any StorageProvider
  public var account: @Sendable (SyncProviderSettings) async -> SyncAccountStatus
  /// Whether the device has been unlocked since it started (`FirstUnlockProbe`), not whether it is unlocked now.
  public var hasUnlockedSinceBoot: @Sendable () async -> Bool
  public var makeVaultID: @Sendable () -> VaultID
  public var makeKeyID: @Sendable () -> KeyID
  /// Set for a store that syncs beside the primary at the location the primary attached (`SyncStoreRoute`): it never attaches on first use, and its
  /// `attach`, `detach` and moves throw `notAttached`, since the location is the primary's to change.
  public var route: SyncStoreRoute?
  /// Set for a primary whose vault syncs these routes beside it, even one stopped for now: such a vault neither moves nor follows a move
  /// (`SyncMoveError.routedStoresUnsupported`), since a move carries only the primary's store.
  public var routedStores: Set<SyncStoreRoute>

  public init(
    locationStore: SyncLocationStore,
    stores: SyncSecureStores,
    automatic: SyncProviderSettings? = nil,
    provider: @escaping @Sendable (SyncProviderSettings) throws(StorageError) -> any StorageProvider,
    account: @escaping @Sendable (SyncProviderSettings) async -> SyncAccountStatus = { _ in .available(nil) },
    hasUnlockedSinceBoot: @escaping @Sendable () async -> Bool,
    makeVaultID: @escaping @Sendable () -> VaultID = VaultSetup.newVaultID,
    makeKeyID: @escaping @Sendable () -> KeyID = { KeyID(UUID.v7()) },
    route: SyncStoreRoute? = nil,
    routedStores: Set<SyncStoreRoute> = []
  ) {
    self.locationStore = locationStore
    self.stores = stores
    self.automatic = automatic
    self.provider = provider
    self.account = account
    self.hasUnlockedSinceBoot = hasUnlockedSinceBoot
    self.makeVaultID = makeVaultID
    self.makeKeyID = makeKeyID
    self.route = route
    self.routedStores = routedStores
  }
}

public struct SyncStartupResult: Sendable {
  public let phase: SyncPhase
  public let location: SyncLocation?
  /// Present only for a vault phase on the attached location; every other phase leaves nothing to sync with.
  public let attachment: SyncAttachment?

  init(phase: SyncPhase, location: SyncLocation? = nil, attachment: SyncAttachment? = nil) {
    self.phase = phase
    self.location = location
    self.attachment = attachment
  }
}
