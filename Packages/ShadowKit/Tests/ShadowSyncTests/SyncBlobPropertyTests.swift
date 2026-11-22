import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("Blob sync properties", TestTimeLimit.property)
struct SyncBlobPropertyTests {
  private static let receipts = ["r0", "r1", "r2"]

  /// Random puts, renames, copies, removals, syncs, compactions and fetches on three replicas over a faulty provider, with no retention, so blobs are
  /// collected as early as the rules allow. Once faults stop and everyone settles, every blob a record names reads back on a replica that joins last.
  @Test("should keep every named blob fetchable under any interleaving of writes, syncs and compactions", arguments: 0..<40)
  func shouldKeepNamedBlobs(seed: UInt64) async throws {
    let provider = FaultInjectingStorageProvider(
      wrapping: InMemoryStorageProvider(serverClock: { SyncFixture.start }), seed: seed,
      plan: FaultPlan(transientFailure: 0.08, lostAcknowledgement: 0.08, staleListing: 0.3, partialPage: 0.3, delayedDelete: 0.3))
    var peers = try await BlobPeers.make(3, provider: provider)
    var generator = SeededGenerator(seed: 0xB10B_0000 + seed)
    var contents: [BlobID: Data] = [:]

    for _ in 0..<80 {
      let peer = peers[generator.int(in: 0...2)]
      let receipt = generator.pick(from: Self.receipts)
      switch generator.int(in: 0...6) {
      case 0:
        let content = generator.data(count: generator.int(in: 0...3_000))
        let id = try await peer.blobs.put(content)
        contents[id] = content
        try await peer.setImage(receipt, id)
      case 1:
        try await peer.setImage(receipt, nil)
      case 2:
        let named = try await peer.images().values.sorted()
        guard !named.isEmpty else { continue }
        try await peer.setImage(receipt, generator.pick(from: named))
      case 3:
        try await peer.setRemoved(receipt, generator.chance(0.5))
      case 4:
        _ = try? await peer.engine.sync()
      case 5:
        _ = try? await peer.engine.compact(force: generator.chance(0.3))
      default:
        let named = try await peer.images().values.sorted()
        guard !named.isEmpty else { continue }
        _ = try? await peer.engine.fetchBlob(generator.pick(from: named))
      }
    }

    provider.setFaultsEnabled(false)
    provider.heal()
    try await peers.settle()
    for _ in 0..<2 {
      for peer in peers.peers { _ = try await peer.engine.compact() }
      try await peers.settle()
    }
    let late = try await peers.join("late")
    try await peers.settle()

    let named = Set(try await late.images().values)
    for peer in peers.peers {
      #expect(Set(try await peer.images().values) == named)
      for id in named { #expect(try await peer.fetched(id) == contents[id], "seed \(seed): \(id) on \(peer.store.replica)") }
    }
  }
}
