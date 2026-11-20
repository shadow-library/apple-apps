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
  /// Called once per settings value; the driver keeps the provider while the settings stay the same.
  public var provider: @Sendable (SyncProviderSettings) throws(StorageError) -> any StorageProvider
  public var account: @Sendable (SyncProviderSettings) async -> SyncAccountStatus
  /// Whether the device has been unlocked since it started (`FirstUnlockProbe`), not whether it is unlocked now.
  public var hasUnlockedSinceBoot: @Sendable () async -> Bool
  public var makeVaultID: @Sendable () -> VaultID
  public var makeKeyID: @Sendable () -> KeyID

  public init(
    locationStore: SyncLocationStore,
    stores: SyncSecureStores,
    automatic: SyncProviderSettings? = nil,
    provider: @escaping @Sendable (SyncProviderSettings) throws(StorageError) -> any StorageProvider,
    account: @escaping @Sendable (SyncProviderSettings) async -> SyncAccountStatus = { _ in .available(nil) },
    hasUnlockedSinceBoot: @escaping @Sendable () async -> Bool,
    makeVaultID: @escaping @Sendable () -> VaultID = VaultSetup.newVaultID,
    makeKeyID: @escaping @Sendable () -> KeyID = { KeyID(UUID.v7()) }
  ) {
    self.locationStore = locationStore
    self.stores = stores
    self.automatic = automatic
    self.provider = provider
    self.account = account
    self.hasUnlockedSinceBoot = hasUnlockedSinceBoot
    self.makeVaultID = makeVaultID
    self.makeKeyID = makeKeyID
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
