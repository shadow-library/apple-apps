import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowSync

/// What `SyncEngine` needs for one attached vault. The device marker lives in the this-device store, so a database restored onto other hardware,
/// or onto this device without its marker, starts as a new replica.
public struct SyncAttachment: Sendable {
  public let location: SyncLocation
  public let provider: any StorageProvider
  public let ring: KeyRing
  let providerID: Int
  private let markerStore: any SecureStore
  let keyServices: SyncKeyServices

  init(
    location: SyncLocation, provider: any StorageProvider, providerID: Int, ring: KeyRing, markerStore: any SecureStore, keyServices: SyncKeyServices
  ) {
    self.location = location
    self.provider = provider
    self.providerID = providerID
    self.ring = ring
    self.markerStore = markerStore
    self.keyServices = keyServices
  }

  public var vault: VaultID { location.vault }

  public func lifecycle(store: VaultStore, device: ReplicaDevice, wallClock: @escaping @Sendable () -> Date = { Date() }) -> ReplicaLifecycle {
    ReplicaLifecycle(store: store, vault: vault, marker: DeviceMarker(store: markerStore), device: device, wallClock: wallClock)
  }

  /// `store` must have been opened with `SyncEngine.migrations` and `SyncEngine.wallClock(preferring: trustedClock)`.
  public func engine(
    store: VaultStore, device: ReplicaDevice, trustedClock: TrustedClock, configuration: SyncConfiguration = .init(),
    wallClock: @escaping @Sendable () -> Date = { Date() }
  ) -> SyncEngine {
    SyncEngine(
      store: store, provider: provider, vault: vault, ring: ring, lifecycle: lifecycle(store: store, device: device, wallClock: wallClock), trustedClock: trustedClock,
      configuration: configuration, wallClock: wallClock)
  }
}
