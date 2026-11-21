import Foundation
import ShadowCore
import ShadowSync

/// A replica that has shown it holds a key: its newest file at the location opened under that key, header and every chunk authenticated against the
/// file's path. Its name and platform come from the vault's replica directory, or else from its manifest; nil when neither names it.
public struct SyncKeyHolder: Sendable, Equatable {
  public let replica: ReplicaID
  public let name: String?
  public let platform: String?
  public let isThisDevice: Bool
}

/// One key of this device's ring and the replicas whose newest file is sealed with it. A replica writes with one key at a time, so it shows under that
/// key only; a key no replica writes with any more lists none.
public struct SyncKeyHolding: Sendable, Equatable {
  public let key: KeyID
  public let holders: [SyncKeyHolder]
}

enum KeyHolderSurvey {
  static let maximumReplicas = 64
  static let maximumFileBytes = 16 << 20

  private struct Files {
    var manifest: StorageObject?
    var segment: (last: Int64, object: StorageObject)?
    var base: (upTo: Int64, object: StorageObject)?

    var newestFirst: [StorageObject] { [manifest, segment?.object, base?.object].compactMap(\.self) }
  }

  /// A file that opens under none of the ring's keys proves nothing and is passed over, as is a replica the directory records as retired.
  static func survey(_ provider: any StorageProvider, ring: KeyRing, directory: ReplicaDirectory, own: ReplicaID) async throws(StorageError) -> [SyncKeyHolding] {
    var files: [ReplicaID: Files] = [:]
    for object in try await provider.listAll(prefix: VaultPath.replicasPrefix) where object.size <= maximumFileBytes {
      switch VaultPath.classify(object.key) {
      case .manifest(let replica):
        files[replica, default: Files()].manifest = object
      case .segment(let replica, _, let last, _):
        if files[replica]?.segment.map({ $0.last < last }) ?? true { files[replica, default: Files()].segment = (last, object) }
      case .basePart(let replica, let upTo, _, _, _):
        if files[replica]?.base.map({ $0.upTo < upTo }) ?? true { files[replica, default: Files()].base = (upTo, object) }
      default:
        continue
      }
    }
    var holders: [KeyID: [SyncKeyHolder]] = [:]
    let replicas = files.keys.filter { !directory.isRetired($0) }.sorted(by: >).prefix(maximumReplicas)
    for replica in replicas {
      guard let (keyID, manifest) = try await heldKey(of: replica, in: files[replica]?.newestFirst ?? [], provider: provider, ring: ring) else { continue }
      let entry = directory.entry(for: replica)
      let holder = SyncKeyHolder(
        replica: replica, name: entry?.name ?? manifest?.deviceName, platform: entry?.platform ?? manifest?.platform, isThisDevice: replica == own)
      holders[keyID, default: []].append(holder)
    }
    return ring.keyIDs.map { key in SyncKeyHolding(key: key, holders: holders[key] ?? []) }
  }

  /// A readable manifest names the key the replica writes with now: one this device lacks rules the replica out, whatever its older files hold. Only an
  /// absent or unreadable manifest falls through to the newest segment and base part.
  private static func heldKey(
    of replica: ReplicaID, in candidates: [StorageObject], provider: any StorageProvider, ring: KeyRing
  ) async throws(StorageError) -> (KeyID, ReplicaManifest?)? {
    for object in candidates {
      guard let data = try await provider.getIfPresent(object.key), let keyID = try? VaultFile.header(of: data).keyID else { continue }
      let isManifest = VaultPath.classify(object.key) == .manifest(replica)
      guard ring.key(keyID) != nil else {
        if isManifest { return nil }
        continue
      }
      if isManifest {
        guard let manifest = try? ReplicaManifestCodec.open(data, at: object.key, vault: ring.vault, keys: ring.key), manifest.replica == replica else { continue }
        return (keyID, manifest)
      }
      guard (try? VaultFile.open(data, path: object.key.rawValue, vault: ring.vault, keys: ring.key)) != nil else { continue }
      return (keyID, nil)
    }
    return nil
  }
}
