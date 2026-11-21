import Foundation
import ShadowCore
import ShadowSync

/// The files at this location a candidate key must open before it joins the ring. The check refuses a key that opens nothing here, such as another
/// vault's key or garbage; it proves nothing about where the key came from, since whoever controls the location can plant a file sealed with a key
/// of its own. Authenticity comes from the phrase's pre-shared-key seal (recovery) and the matched code (exchange). The newest manifests come first,
/// since every replica rewrites its own under the key it writes with; segments and base parts follow, smallest first.
struct HeldFiles: Sendable {
  static let maximumManifests = 64
  static let maximumOtherFiles = 32
  static let maximumFileBytes = 16 << 20

  private struct Manifest: Sendable {
    let key: ObjectKey
    let data: Data
    let keyID: KeyID
  }

  private let provider: any StorageProvider
  private let vault: VaultID
  private let manifests: [Manifest]
  private let others: [StorageObject]

  /// Read from unauthenticated manifest headers: a hint of which copies to look for, never proof that a key belongs to the vault.
  var namedKeys: Set<KeyID> { Set(manifests.map(\.keyID)) }

  static func survey(_ provider: any StorageProvider, vault: VaultID) async throws(StorageError) -> HeldFiles {
    var manifestKeys: [(replica: ReplicaID, key: ObjectKey)] = []
    var others: [StorageObject] = []
    for object in try await provider.listAll(prefix: VaultPath.replicasPrefix) where object.size <= maximumFileBytes {
      switch VaultPath.classify(object.key) {
      case .manifest(let replica): manifestKeys.append((replica, object.key))
      case .segment, .basePart: others.append(object)
      default: continue
      }
    }
    let newestFirst = manifestKeys.sorted { $0.replica > $1.replica }.prefix(maximumManifests).map(\.key)
    var manifests: [Manifest] = []
    for key in newestFirst {
      guard let data = try await provider.getIfPresent(key), let header = try? VaultFile.header(of: data), header.vault == vault else { continue }
      manifests.append(Manifest(key: key, data: data, keyID: header.keyID))
    }
    let smallestFirst = others.sorted { ($0.size, $0.key.rawValue) < ($1.size, $1.key.rawValue) }
    return HeldFiles(provider: provider, vault: vault, manifests: manifests, others: Array(smallestFirst.prefix(maximumOtherFiles)))
  }

  /// The ids of `candidates` that opened a whole file listed here for this vault, header and every chunk authenticated under the candidate's bytes.
  func confirm(_ candidates: [VaultKey]) async throws(StorageError) -> Set<KeyID> {
    var remaining = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var confirmed: Set<KeyID> = []
    for manifest in manifests where !remaining.isEmpty {
      guard let key = remaining[manifest.keyID], opens(manifest.data, at: manifest.key, with: key) else { continue }
      confirmed.insert(key.id)
      remaining[key.id] = nil
    }
    for object in others where !remaining.isEmpty {
      guard let data = try await provider.getIfPresent(object.key), let header = try? VaultFile.header(of: data), let key = remaining[header.keyID] else { continue }
      guard opens(data, at: object.key, with: key) else { continue }
      confirmed.insert(key.id)
      remaining[key.id] = nil
    }
    return confirmed
  }

  private func opens(_ data: Data, at key: ObjectKey, with candidate: VaultKey) -> Bool {
    (try? VaultFile.open(data, path: key.rawValue, vault: vault) { $0 == candidate.id ? candidate : nil }) != nil
  }
}
