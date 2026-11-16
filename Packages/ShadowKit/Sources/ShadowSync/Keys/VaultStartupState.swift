import Foundation
import ShadowCore

public enum StorageAvailability: Sendable, Equatable {
  case unavailable
  case available
}

public struct VaultObservation: Sendable, Equatable {
  public var storage: StorageAvailability
  public var vault: VaultID?
  public var heldKeys: Set<KeyID>
  /// Read from unauthenticated file headers: the storage provider can name any key id and any replica here.
  public var namedKeys: [KeyID: Set<ReplicaID>]

  public init(storage: StorageAvailability, vault: VaultID?, heldKeys: Set<KeyID>, namedKeys: [KeyID: Set<ReplicaID>]) {
    self.storage = storage
    self.vault = vault
    self.heldKeys = heldKeys
    self.namedKeys = namedKeys
  }
}

public enum VaultStartupState: Sendable, Equatable {
  case noStorageAccount
  case noVault
  case awaitingKey(vault: VaultID)
  case partiallyReadable(vault: VaultID, missing: [KeyID: Set<ReplicaID>])
  case ready(vault: VaultID)

  public init(_ observation: VaultObservation) {
    guard observation.storage == .available else {
      self = .noStorageAccount
      return
    }
    guard let vault = observation.vault else {
      self = .noVault
      return
    }
    guard !observation.heldKeys.isEmpty else {
      self = .awaitingKey(vault: vault)
      return
    }
    let missing = observation.namedKeys.filter { !observation.heldKeys.contains($0.key) }
    self = missing.isEmpty ? .ready(vault: vault) : .partiallyReadable(vault: vault, missing: missing)
  }

  public var canWrite: Bool {
    switch self {
    case .partiallyReadable, .ready: true
    case .noStorageAccount, .noVault, .awaitingKey: false
    }
  }
}
