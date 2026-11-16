import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private enum SyncRandomChange: Sendable {
  case set(EntityRef, String)
  case purge(EntityRef)
  case append(EntityRef, String)
  case revise(EntityRef, String)

  static func make(_ generator: inout SeededGenerator) -> SyncRandomChange {
    let text = generator.asciiString(maxLength: 24)
    switch generator.int(in: 0...9) {
    case 0...4: return .set(ref(SyncFixture.note, "n", generator.int(in: 0...4)), text)
    case 5: return .purge(ref(SyncFixture.note, "n", generator.int(in: 0...4)))
    case 6, 7: return .append(ref(SyncFixture.message, "m", Int(truncatingIfNeeded: generator.next() >> 1)), text)
    default: return generator.chance(0.15) ? .purge(ref(SyncFixture.draft, "d", generator.int(in: 0...2))) : .revise(ref(SyncFixture.draft, "d", generator.int(in: 0...2)), text)
    }
  }

  private static func ref(_ kind: EntityKind, _ prefix: String, _ index: Int) -> EntityRef {
    EntityRef(kind: kind, key: ReplicaFixture.key("\(prefix)\(index)"))
  }

  /// Returns nil when the store refuses the change, as it does for an entity already purged.
  func write(to store: VaultStore) async throws -> ChangeRecord? {
    do {
      return try await store.write { transaction in
        switch self {
        case .set(let ref, let text): try transaction.set(ref, ["title": .string(text)])
        case .purge(let ref): try transaction.purge(ref)
        case .append(let ref, let text): try transaction.append(ref, item: ["text": .string(text)])
        case .revise(let ref, let text): try transaction.revise(ref, body: .string(text)).record
        }
      }
    } catch {
      guard case .entityPurged = error else { throw error }
      return nil
    }
  }
}

private func tolerateStorageFailure(_ body: () async throws(SyncError) -> Void) async throws {
  do {
    try await body()
  } catch {
    guard case .storage = error else { throw error }
  }
}

private func converge(_ generator: inout SeededGenerator) async throws {
  let inner = InMemoryStorageProvider(pageSize: generator.int(in: 2...8))
  let plan = FaultPlan(transientFailure: 0.03, lostAcknowledgement: 0.1, staleListing: 0.6, partialPage: 0.3, delayedDelete: 0, staleOperations: 1...40)
  let provider = FaultInjectingStorageProvider(wrapping: inner, seed: generator.next(), plan: plan)
  let configuration = SyncConfiguration(maximumSegmentLines: generator.int(in: 1...3), uploadPassBytes: generator.chance(0.5) ? 600 : nil)
  let registry = SyncFixture.richRegistry
  let peers = try await SyncPeers.make(3, provider: provider, configuration: configuration, registries: Array(repeating: registry, count: 3))
  let replicas = peers.peers.map(\.store.replica)
  var written: [Data] = []
  var seen: [Data: ChangeRecord] = [:]
  for _ in 0..<generator.int(in: 10...24) {
    let peer = peers[generator.int(in: 0...2)]
    switch generator.int(in: 0...10) {
    case 0...2:
      for _ in 0..<generator.int(in: 1...3) {
        if let record = try await SyncRandomChange.make(&generator).write(to: peer.store) { written.append(record.canonicalBytes()) }
      }
    case 3...5:
      try await tolerateStorageFailure { () async throws(SyncError) in _ = try await peer.engine.upload() }
    case 6...8:
      try await tolerateStorageFailure { () async throws(SyncError) in _ = try await peer.engine.download() }
    default:
      for record in try await SyncPlant.records(in: inner, ring: peers[0].ring) { seen[record.canonicalBytes()] = record }
      try await SyncPlant.compact(peer, in: inner)
    }
    peers.clock.set(peers.clock.now.addingTimeInterval(Double(generator.int(in: 0...5))))
  }
  provider.setFaultsEnabled(false)
  provider.heal()

  try await peers.settle()

  for record in try await SyncPlant.records(in: inner, ring: peers[0].ring) { seen[record.canonicalBytes()] = record }
  let expected = try await SyncPlant.reference(in: inner, ring: peers[0].ring, registry: registry, also: Array(seen.values))
  guard written.allSatisfy({ seen[$0] != nil }) else { throw SyncFixtureFailure("a change written locally never reached storage") }
  for (index, peer) in peers.peers.enumerated() {
    guard try await peer.digest() == expected else { throw SyncFixtureFailure("peer \(index) differs from the reference") }
    guard try await peer.pendingLines().isEmpty else { throw SyncFixtureFailure("peer \(index) still has pending changes") }
    guard peer.store.replica == replicas[index] else { throw SyncFixtureFailure("peer \(index) was re-minted") }
    guard try await peer.engine.download().held.isEmpty else { throw SyncFixtureFailure("peer \(index) still holds files") }
  }
}

@Suite("SyncEngine convergence")
struct SyncConvergeTests {
  @Test("should converge three replicas to the merge of every change after random writes, uploads, downloads and compactions on a hostile provider")
  func shouldConverge() async throws {
    try await forAll(iterations: 60, seed: 0xC0_4E_E6) { generator in
      try await converge(&generator)
    }
  }
}
