import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization

@testable import ShadowSync

struct ReplicaFixtureFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

enum ReplicaFixture {
  static let note = kind("note")
  static let registry = SyncKernelSchema.registry(version: 3, adding: [EntitySchema(kind: note, shape: .record(fields: ["title": .register]), syncClass: .general)])
  static let start = Date(timeIntervalSince1970: 1_700_000_000)
  static let startMillis: Int64 = 1_700_000_000_000
  static let phone = ReplicaDevice(name: "Phone", platform: "iOS", appVersion: "1.0")
  static let mac = ReplicaDevice(name: "Mac", platform: "macOS", appVersion: "1.0")
  static let crash = ReplicaLifecycleError.corruptState("injected crash")

  static var vault: VaultID {
    guard let vault = VaultID("vault-one") else { preconditionFailure("fixture vault id is valid") }
    return vault
  }

  static func kind(_ name: String) -> EntityKind {
    guard let kind = EntityKind(name) else { preconditionFailure("fixture kind is valid") }
    return kind
  }

  static func key(_ text: String) -> EntityKey {
    guard let key = EntityKey(text) else { preconditionFailure("fixture key is valid") }
    return key
  }

  static func replica(_ text: String) -> ReplicaID {
    guard let replica = ReplicaID(text) else { preconditionFailure("fixture replica id is valid") }
    return replica
  }

  static func tag(_ index: Int) -> ContentTag {
    let hex = String(index, radix: 16)
    guard let tag = ContentTag(String(repeating: "0", count: 32 - hex.count) + hex) else { preconditionFailure("fixture tag is valid") }
    return tag
  }

  static func point(_ last: Int64, _ tag: Int) -> StreamPoint {
    StreamPoint(last: last, tag: self.tag(tag))
  }

  static func open(_ location: StoreLocation = .inMemory) throws -> VaultStore {
    try VaultStore.open(location, registry: registry, migrations: ReplicaLifecycle.migrations, wallClock: { start })
  }

  static func marker(_ keychain: InMemoryKeychain, _ device: String) -> DeviceMarker {
    DeviceMarker(store: keychain.device(device).store(service: "marker", scope: .device))
  }

  static func lifecycle(
    _ store: VaultStore, marker: DeviceMarker, device: ReplicaDevice = phone, minter: ReplicaMinter = ReplicaMinter(), crashAt step: ReplicaLifecycleStep? = nil
  ) -> ReplicaLifecycle {
    let checkpoint: @Sendable (ReplicaLifecycleStep) throws(ReplicaLifecycleError) -> Void = { reached throws(ReplicaLifecycleError) in
      if reached == step { throw crash }
    }
    return ReplicaLifecycle(store: store, vault: vault, marker: marker, device: device, wallClock: { start }, makeReplicaID: minter.next, checkpoint: checkpoint)
  }

  static func records(_ store: VaultStore) async throws -> [ChangeRecord] {
    try await store.pendingChanges(limit: Int.max).map { try ChangeRecord(json: CanonicalJSON.decode($0.line)) }
  }

  static func replicaRecords(_ records: [ChangeRecord], for replica: ReplicaID) -> [ChangeRecord] {
    records.filter { $0.entity == SyncKernelSchema.replicaKind && $0.key.rawValue == replica.description }
  }

  static func copyDatabase(from source: URL, to target: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    for suffix in ["", "-wal"] {
      let from = URL(filePath: source.path(percentEncoded: false) + suffix)
      let to = URL(filePath: target.path(percentEncoded: false) + suffix)
      if manager.fileExists(atPath: to.path(percentEncoded: false)) { try manager.removeItem(at: to) }
      if manager.fileExists(atPath: from.path(percentEncoded: false)) { try manager.copyItem(at: from, to: to) }
    }
  }
}

final class ReplicaMinter: Sendable {
  private let minted = Mutex<[ReplicaID]>([])

  var all: [ReplicaID] {
    minted.withLock { $0 }
  }

  var next: @Sendable () -> ReplicaID {
    { self.mint() }
  }

  private func mint() -> ReplicaID {
    let replica = ReplicaID(UUID.v7())
    minted.withLock { $0.append(replica) }
    return replica
  }
}

final class ReplicaTemporaryDirectory: Sendable {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory.appending(path: "shadow-replica-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  func database(_ name: String) -> URL {
    url.appending(path: "\(name).sqlite")
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
