import Foundation
import ShadowCore
import ShadowKeychain

public enum DeviceMarkerStatus: Sendable, Equatable {
  case matches
  case missing
  case other(ReplicaID)
  case unreadable
}

public struct DeviceMarker: Sendable {
  private let store: any SecureStore

  /// Needs a device-scoped store (this-device-only items); a synced store would carry the marker to other hardware and defeat the check.
  public init(store: any SecureStore) {
    self.store = store
  }

  public static func itemName(vault: VaultID) -> String {
    "replica-marker/\(vault.rawValue)"
  }

  public func status(vault: VaultID, replica: ReplicaID) -> DeviceMarkerStatus {
    let data: Data?
    do {
      data = try store.data(forKey: Self.itemName(vault: vault))
    } catch {
      return .unreadable
    }
    guard let data else { return .missing }
    guard let text = String(data: data, encoding: .utf8), let marked = ReplicaID(text) else { return .unreadable }
    return marked == replica ? .matches : .other(marked)
  }

  public func claim(vault: VaultID, replica: ReplicaID) throws(ReplicaFileError) {
    do {
      try store.setData(Data(replica.description.utf8), forKey: Self.itemName(vault: vault))
    } catch {
      throw Self.failure(error)
    }
  }

  /// Overwrites the item only when it exists and is not a replica id; the caller uses it after the device has been unlocked.
  public func repair(vault: VaultID, replica: ReplicaID) throws(ReplicaFileError) {
    let data: Data?
    do {
      data = try store.data(forKey: Self.itemName(vault: vault))
    } catch {
      throw Self.failure(error)
    }
    guard let data else { throw .markerNotRepairable }
    guard String(data: data, encoding: .utf8).flatMap(ReplicaID.init) == nil else { throw .markerNotRepairable }
    try claim(vault: vault, replica: replica)
  }

  public func clear(vault: VaultID) throws(ReplicaFileError) {
    do {
      try store.removeValue(forKey: Self.itemName(vault: vault))
    } catch {
      throw Self.failure(error)
    }
  }

  private static func failure(_ error: SecureStoreError) -> ReplicaFileError {
    guard case .unexpectedStatus(let status) = error else { return .keychain(error.code) }
    return .keychain("\(error.code) \(status)")
  }
}
