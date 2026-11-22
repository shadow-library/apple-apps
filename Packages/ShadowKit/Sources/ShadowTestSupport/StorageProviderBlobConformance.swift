import Foundation
import ShadowCore
import ShadowStore
import ShadowSync

/// Blob cases of the conformance suite, run through the sync engine itself: two replicas on separate stores share the provider and one key ring.
struct BlobChecker {
  private static let maxPolls = 2000
  private static let vault: VaultID = {
    guard let vault = VaultID("conformance-blobs") else { preconditionFailure("the conformance vault id is valid") }
    return vault
  }()
  private static let registry = SyncKernelSchema.registry(version: 1, adding: [])

  let provider: any StorageProvider
  let consistency: StorageProviderConformance.Consistency

  func run() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "shadow-blob-conformance-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let keychain = InMemoryKeychain()
    let configuration = SyncConfiguration(blobPartBytes: 4096)
    let writer = try await replica("writer", root: root, keychain: keychain, configuration: configuration, createsKey: true)
    let reader = try await replica("reader", root: root, keychain: keychain, configuration: configuration, createsKey: false)

    let contents = [Self.payload(10_000, salt: 1), Data(), Self.payload(37, salt: 2)]
    var ids: [BlobID] = []
    for content in contents { ids.append(try await writer.blobs.put(content)) }
    _ = try await step("an upload puts every waiting blob") { () async throws(SyncError) in try await writer.engine.upload() }
    for id in ids {
      guard try await writer.blobs.status(of: id) == .stored else { throw violation("an upload puts every waiting blob", "\(id) is not stored") }
    }

    var partKeys: [BlobID: [ObjectKey]] = [:]
    for id in ids { partKeys[id] = try await completeParts(of: id) }
    try await expectRootListing(containing: Set(partKeys.values.joined()))
    for (index, id) in ids.enumerated() {
      let fetched = try await fetch(id, from: reader)
      guard fetched == contents[index] else { throw violation("a fetched blob reads back byte for byte", "\(id) differs") }
    }

    let removed = ids[0]
    try await step("blob parts are deleted by their recorded names") { () async throws(StorageError) in try await provider.delete(partKeys[removed] ?? []) }
    try await expectBlobListing(of: removed, equals: [])
    for id in ids.dropFirst() {
      guard try await listed(id) == partKeys[id] else { throw violation("deleting one blob's parts leaves every other blob", "\(id) changed") }
    }
    let late = try await replica("late", root: root, keychain: keychain, configuration: configuration, createsKey: false)
    try await expectMissing(removed, from: late)
    guard try await fetch(ids[2], from: late) == contents[2] else { throw violation("a replica joining later fetches a stored blob", "\(ids[2]) differs") }
  }

  private struct Replica {
    let engine: SyncEngine
    let blobs: VaultBlobs
  }

  private func replica(_ name: String, root: URL, keychain: InMemoryKeychain, configuration: SyncConfiguration, createsKey: Bool) async throws -> Replica {
    let device = keychain.device(name)
    let trusted = TrustedClock()
    let store = try VaultStore.open(
      .file(root.appending(path: name, directoryHint: .isDirectory).appending(path: "vault.sqlite")), registry: Self.registry, migrations: SyncEngine.migrations,
      wallClock: SyncEngine.wallClock(preferring: trusted))
    let ring = KeyRing(vault: Self.vault, store: device.store(service: "keys", scope: .synced))
    if createsKey { _ = try ring.createKey() }
    keychain.deliver()
    let lifecycle = ReplicaLifecycle(
      store: store, vault: Self.vault, marker: DeviceMarker(store: device.store(service: "marker", scope: .device)),
      device: ReplicaDevice(name: name, platform: "conformance", appVersion: "1"))
    let engine = SyncEngine(
      store: store, provider: provider, vault: Self.vault, ring: ring, lifecycle: lifecycle, trustedClock: trusted, configuration: configuration)
    _ = try await engine.start()
    return Replica(engine: engine, blobs: try VaultBlobs(store: store, maximumBytes: configuration.maximumBlobBytes))
  }

  /// The listed parts of one blob: a single complete, numbered set, each within the provider's object limit.
  private func completeParts(of id: BlobID) async throws -> [ObjectKey] {
    let rule = "a blob's parts are listed as one complete set within the object limit"
    for _ in 0..<Self.maxPolls {
      let keys = try await listed(id)
      let counts = Set(
        keys.compactMap { key -> Int? in
          guard case .blobPart(_, _, let parts) = VaultPath.classify(key) else { return nil }
          return parts
        })
      if let parts = counts.first, counts.count == 1, keys.count == parts {
        let sizes = try await step(rule) { () async throws(StorageError) in try await provider.listAll(prefix: VaultPath.blobPrefix(id.description)) }.map(\.size)
        guard sizes.allSatisfy({ $0 <= provider.capabilities.maxObjectBytes }) else { throw violation(rule, "\(id) has a part over the limit") }
        return keys
      }
      guard consistency == .eventual else { throw violation(rule, "\(id) lists \(keys.map(\.rawValue))") }
      await Task.yield()
    }
    throw violation(rule, "\(id) never listed completely")
  }

  /// Compaction finds every stored blob with one listing of `blobs/`, across pages.
  private func expectRootListing(containing expected: Set<ObjectKey>) async throws {
    let rule = "one listing of blobs/ shows every blob part and nothing else"
    var listed: [ObjectKey] = []
    for _ in 0..<Self.maxPolls {
      listed = try await step(rule) { () async throws(StorageError) in try await provider.listAll(prefix: VaultPath.blobsPrefix) }.map(\.key)
      if expected.isSubset(of: listed) { break }
      guard consistency == .eventual else { break }
      await Task.yield()
    }
    guard expected.isSubset(of: listed) else { throw violation(rule, "\(expected.subtracting(listed).count) parts are not listed") }
    let foreign = listed.filter { if case .blobPart = VaultPath.classify($0) { false } else { true } }
    guard foreign.isEmpty else { throw violation(rule, "\(foreign.map(\.rawValue)) are listed") }
  }

  private func listed(_ id: BlobID) async throws -> [ObjectKey] {
    try await step("a blob's parts are listed under its name") { () async throws(StorageError) in
      try await provider.listAll(prefix: VaultPath.blobPrefix(id.description))
    }.map(\.key)
  }

  private func expectBlobListing(of id: BlobID, equals expected: [ObjectKey]) async throws {
    for _ in 0..<Self.maxPolls {
      if try await listed(id) == expected { return }
      guard consistency == .eventual else { break }
      await Task.yield()
    }
    throw violation("deleted blob parts leave the listing", "\(id) is still listed")
  }

  private func fetch(_ id: BlobID, from replica: Replica) async throws -> Data {
    let rule = "a fetched blob reads back byte for byte"
    for _ in 0..<Self.maxPolls {
      do {
        return try Data(contentsOf: try await replica.engine.fetchBlob(id))
      } catch let error as BlobError {
        guard case .missing = error, consistency == .eventual else { throw violation(rule, "\(id) threw \(error)") }
      }
      await Task.yield()
    }
    throw violation(rule, "\(id) was never fetched")
  }

  private func expectMissing(_ id: BlobID, from replica: Replica) async throws {
    let rule = "a deleted blob is missing to a replica that never held it"
    for _ in 0..<Self.maxPolls {
      do {
        _ = try await replica.engine.fetchBlob(id)
      } catch {
        guard case .missing = error else { throw violation(rule, "\(id) threw \(error)") }
        return
      }
      guard consistency == .eventual else { break }
      await Task.yield()
    }
    throw violation(rule, "\(id) is still fetched")
  }

  private func step<T>(_ rule: String, _ body: () async throws(StorageError) -> T) async throws -> T {
    do {
      return try await body()
    } catch {
      throw violation(rule, "unexpected \(error)")
    }
  }

  private func step<T>(_ rule: String, _ body: () async throws(SyncError) -> T) async throws -> T {
    do {
      return try await body()
    } catch {
      throw violation(rule, "unexpected \(error)")
    }
  }

  private func violation(_ rule: String, _ detail: String) -> StorageConformanceViolation {
    StorageConformanceViolation(rule: rule, detail: detail)
  }

  private static func payload(_ count: Int, salt: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8 &+ salt) })
  }
}
