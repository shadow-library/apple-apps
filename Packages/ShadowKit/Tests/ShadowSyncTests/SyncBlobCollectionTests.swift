import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("Blob collection", TestTimeLimit.standard)
struct SyncBlobCollectionTests {
  private struct Scene {
    let provider: BlobWatchingProvider
    var peers: BlobPeers
    let dropped: BlobID
    let kept: BlobID
    let droppedContent: Data
  }

  /// Two receipts with a blob each are synced to both peers, then the first peer clears one receipt's image.
  private func scene(_ count: Int = 2) async throws -> Scene {
    let provider = BlobWatchingProvider()
    let peers = try await BlobPeers.make(count, provider: provider)
    let droppedContent = BlobFixture.content(5_000, seed: 21)
    let dropped = try await peers[0].blobs.put(droppedContent)
    let kept = try await peers[0].blobs.put(BlobFixture.content(5_000, seed: 22))
    try await peers[0].setImage("r1", dropped)
    try await peers[0].setImage("r2", kept)
    try await peers.settle()
    try await peers[0].setImage("r1", nil)
    _ = try await peers[0].engine.sync()
    return Scene(provider: provider, peers: peers, dropped: dropped, kept: kept, droppedContent: droppedContent)
  }

  @Test("should keep an unnamed blob until every active replica has published that it applied the change dropping it")
  func shouldWaitForDelivery() async throws {
    let scene = try await scene()

    _ = try await scene.peers[0].engine.compact()

    #expect(scene.provider.deleted.isEmpty)
    #expect(!(try await scene.provider.blobKeys(scene.dropped)).isEmpty)
    #expect(try await scene.peers[0].blobRow(scene.dropped)?.released != nil)
  }

  @Test("should keep a blob another replica named again before it saw the change dropping it, even while that change is unsent")
  func shouldKeepARacingReference() async throws {
    var scene = try await scene()
    try await scene.peers[1].setImage("r3", scene.dropped)
    _ = try await scene.peers[0].engine.compact()
    _ = try await scene.peers[1].engine.download()
    _ = try await scene.peers[1].engine.compact()
    _ = try await scene.peers[0].engine.compact()
    #expect(scene.provider.deleted.isEmpty)

    try await scene.peers.settle()
    _ = try await scene.peers[0].engine.compact()

    #expect(scene.provider.deleted.isEmpty)
    let late = try await scene.peers.join("late")
    try await scene.peers.settle()
    #expect(try await late.fetched(scene.dropped) == scene.droppedContent)
  }

  @Test("should keep a blob whose dropping change was still unsent when compaction released it")
  func shouldKeepWhenDropUnsentAtRelease() async throws {
    let provider = BlobWatchingProvider()
    var peers = try await BlobPeers.make(2, provider: provider)
    let content = BlobFixture.content(5_000, seed: 26)
    let id = try await peers[0].blobs.put(content)
    try await peers[0].setImage("r1", id)
    try await peers.settle()
    let first = peers[0]
    peers.hooks.onNextCompaction(of: "peer0") { try? await first.setImage("r1", nil) }

    _ = try await peers[0].engine.compact()
    let row = try await peers[0].blobRow(id)
    let lastSequence = try await peers[0].store.read { try $0.lastSequence() }
    #expect(row?.releasePoints?[peers[0].store.replica] == lastSequence)
    try await peers[1].setImage("r3", id)
    for _ in 0..<3 { _ = try await peers[0].engine.compact() }

    #expect(provider.deleted.isEmpty)
    _ = try await peers[1].engine.sync()
    let late = try await peers.join("late")
    try await peers.settle()
    #expect(try await late.images().values.contains(id))
    #expect(try await late.fetched(id) == content)
  }

  @Test("should restart a release when a stream it names retires, so an offline peer that never saw the drop keeps the blob")
  func shouldRestartWhenTheDroppingStreamRetires() async throws {
    let provider = BlobWatchingProvider()
    var peers = try await BlobPeers.make(3, provider: provider)
    let content = BlobFixture.content(5_000, seed: 27)
    let id = try await peers[0].blobs.put(content)
    try await peers[0].setImage("r1", id)
    try await peers.settle()
    try await peers[1].setImage("r1", nil)
    _ = try await peers[1].engine.sync()
    _ = try await peers[0].engine.sync()
    _ = try await peers[0].engine.compact()
    let dropper = peers[1].store.replica
    #expect(try await peers[0].blobRow(id)?.releasePoints?[dropper] != nil)
    let marker = peers.keychain.device("peer1").store(service: "marker", scope: .device)
    for key in try marker.allKeys() { try marker.removeValue(forKey: key) }
    _ = try await peers[1].engine.upload()
    #expect(peers[1].store.replica != dropper)
    _ = try await peers[0].engine.sync()
    #expect(try await peers[0].lifecycle.directory().isRetired(dropper))
    try await peers[2].setImage("r3", id)

    for _ in 0..<2 { _ = try await peers[0].engine.compact() }

    #expect(provider.deleted.isEmpty)
    #expect(try await peers[0].blobRow(id)?.releaseRetired.contains(dropper) == true)
    _ = try await peers[2].engine.sync()
    try await peers.settle()
    _ = try await peers[0].engine.compact()
    #expect(provider.deleted.isEmpty)
    let late = try await peers.join("late")
    try await peers.settle()
    #expect(try await late.fetched(id) == content)
  }

  @Test("should not put a downloaded blob again for a new reference while storage still lists it")
  func shouldNotRestoreAStoredBlob() async throws {
    let scene = try await scene()
    _ = try await scene.peers[1].fetched(scene.kept)
    let puts = scene.provider.blobPuts.count

    try await scene.peers[1].setImage("r3", scene.kept)
    _ = try await scene.peers[1].engine.upload()

    #expect(scene.provider.blobPuts.count == puts)
    #expect(try await scene.peers[1].blobs.status(of: scene.kept) == .downloaded)
  }

  @Test("should delete exactly the recorded parts of an unnamed blob and keep a named one")
  func shouldDeleteByRecordedNames() async throws {
    let scene = try await scene()
    let droppedKeys = try await scene.provider.blobKeys(scene.dropped)
    _ = try await scene.peers[0].engine.compact()
    try await scene.peers.settle()

    _ = try await scene.peers[0].engine.compact()

    #expect(Set(scene.provider.deleted) == Set(droppedKeys))
    #expect(try await scene.provider.blobKeys(scene.dropped).isEmpty)
    #expect(!(try await scene.provider.blobKeys(scene.kept)).isEmpty)
    #expect(try await scene.peers[0].blobs.status(of: scene.dropped) == .removed)
    #expect(try await scene.peers[0].blobs.localURL(of: scene.dropped) != nil)
    #expect(try await scene.peers[0].blobs.status(of: scene.kept) == .stored)
  }

  @Test("should never delete a blob another replica put")
  func shouldLeaveOthersBlobs() async throws {
    let scene = try await scene()
    _ = try await scene.peers[1].fetched(scene.dropped)
    try await scene.peers.settle()

    _ = try await scene.peers[1].engine.compact()

    #expect(scene.provider.deleted.isEmpty)
    #expect(try await scene.peers[1].blobs.status(of: scene.dropped) == nil)
  }

  @Test("should keep the blob of a removed record so restoring the record finds it")
  func shouldKeepRemovedRecordsBlob() async throws {
    let provider = BlobWatchingProvider()
    let peers = try await BlobPeers.make(2, provider: provider)
    let content = BlobFixture.content(800, seed: 23)
    let id = try await peers[0].blobs.put(content)
    try await peers[0].setImage("r1", id)
    try await peers.settle()
    try await peers[0].setRemoved("r1", true)
    try await peers.settle()

    for peer in peers.peers { _ = try await peer.engine.compact() }
    try await peers.settle()
    for peer in peers.peers { _ = try await peer.engine.compact() }
    try await peers[1].setRemoved("r1", false)
    try await peers.settle()

    #expect(provider.deleted.isEmpty)
    #expect(try await peers[1].fetched(id) == content)
  }

  @Test("should delete the blob of a purged record")
  func shouldDeletePurgedRecordsBlob() async throws {
    let provider = BlobWatchingProvider()
    let peers = try await BlobPeers.make(2, provider: provider)
    let id = try await peers[0].blobs.put(BlobFixture.content(800, seed: 24))
    try await peers[0].setImage("r1", id)
    try await peers.settle()
    try await peers[1].store.write { transaction in _ = try transaction.purge(BlobFixture.ref("r1")) }
    try await peers.settle()

    _ = try await peers[0].engine.compact()
    try await peers.settle()
    _ = try await peers[0].engine.compact()

    #expect(try await provider.blobKeys(id).isEmpty)
  }

  @Test("should let a replica joining after compaction fetch every blob a record names")
  func shouldServeALateJoiner() async throws {
    var scene = try await scene()
    _ = try await scene.peers[0].engine.compact(force: true)
    try await scene.peers.settle()
    _ = try await scene.peers[0].engine.compact(force: true)
    #expect(try await scene.provider.blobKeys(scene.dropped).isEmpty)

    let late = try await scene.peers.join("late")
    try await scene.peers.settle()

    let images = try await late.images()
    #expect(images.values.contains(scene.kept))
    #expect(!images.values.contains(scene.dropped))
    for id in images.values { _ = try await late.fetched(id) }
  }

  @Test("should put a removed blob back when a late change names it again")
  func shouldRestoreOnLateReference() async throws {
    var scene = try await scene()
    _ = try await scene.peers[1].fetched(scene.dropped)
    _ = try await scene.peers[0].engine.compact()
    try await scene.peers.settle()
    _ = try await scene.peers[0].engine.compact()
    #expect(try await scene.provider.blobKeys(scene.dropped).isEmpty)

    try await scene.peers[1].setImage("r3", scene.dropped)
    _ = try await scene.peers[1].engine.sync()

    #expect(!(try await scene.provider.blobKeys(scene.dropped)).isEmpty)
    let late = try await scene.peers.join("late")
    try await scene.peers.settle()
    #expect(try await late.fetched(scene.dropped) == scene.droppedContent)
    _ = try await scene.peers[0].engine.compact()
    #expect(try await scene.peers[0].blobs.status(of: scene.dropped) == .waitingToUpload)
  }

  @Test("should put back a named blob storage lost, from the device that holds it")
  func shouldRepairLostBlob() async throws {
    let scene = try await scene()
    try await scene.provider.inner.delete(try await scene.provider.blobKeys(scene.kept))

    _ = try await scene.peers[0].engine.compact()
    _ = try await scene.peers[0].engine.upload()

    #expect(!(try await scene.provider.blobKeys(scene.kept)).isEmpty)
    #expect(try await scene.peers[0].blobs.status(of: scene.kept) == .stored)
  }

  @Test("should drop a removed blob's local file once the retention has passed again")
  func shouldEvictAfterRetention() async throws {
    let scene = try await scene()
    _ = try await scene.peers[0].engine.compact()
    try await scene.peers.settle()
    _ = try await scene.peers[0].engine.compact()
    #expect(try await scene.peers[0].blobs.status(of: scene.dropped) == .removed)

    _ = try await scene.peers[0].engine.compact()

    #expect(try await scene.peers[0].blobs.status(of: scene.dropped) == nil)
    #expect(try await scene.peers[0].blobs.localURL(of: scene.dropped) == nil)
  }

  @Test("should keep a blob put but not yet named for the retention period")
  func shouldKeepFreshBlob() async throws {
    let clock = SyncSettableClock(SyncFixture.start)
    let provider = BlobWatchingProvider(wrapping: InMemoryStorageProvider())
    let configuration = SyncConfiguration(blobPartBytes: 4096, blobRetention: .seconds(60))
    let peers = try await BlobPeers.make(1, provider: provider, configuration: configuration, clock: clock)
    let id = try await peers[0].blobs.put(BlobFixture.content(100, seed: 25))
    _ = try await peers[0].engine.upload()
    _ = try await peers[0].engine.compact()
    clock.set(SyncFixture.start.addingTimeInterval(30))
    _ = try await peers[0].engine.compact()
    #expect(!(try await provider.blobKeys(id)).isEmpty)

    clock.set(SyncFixture.start.addingTimeInterval(61))
    _ = try await peers[0].engine.compact()

    #expect(try await provider.blobKeys(id).isEmpty)
  }

  @Test("should restart every release when the replica is re-minted")
  func shouldRestartReleasesOnRemint() async throws {
    let scene = try await scene()
    _ = try await scene.peers[0].engine.compact()
    #expect(try await scene.peers[0].blobRow(scene.dropped)?.released != nil)

    let replica = scene.peers[0].store.replica
    let marker = scene.peers.keychain.device("peer0").store(service: "marker", scope: .device)
    for key in try marker.allKeys() { try marker.removeValue(forKey: key) }

    _ = try await scene.peers[0].engine.upload()

    #expect(scene.peers[0].store.replica != replica)
    #expect(try await scene.peers[0].blobRow(scene.dropped)?.released == nil)
  }

  @Test("should publish applied points only from a moment without unsent changes")
  func shouldPublishSettledPoints() async throws {
    let first = ReplicaFixture.replica("019a0000-0000-7000-8000-000000000001")
    let own = ReplicaFixture.replica("019a0000-0000-7000-8000-000000000002")
    let early = StreamPoint(last: 3, tag: ReplicaFixture.tag(1))
    let late = StreamPoint(last: 9, tag: ReplicaFixture.tag(2))
    let store = try SyncFixture.open()

    let published = try await store.write { transaction in
      let settled = try SyncPublishedTable.publishable(current: [first: early], hasPending: false, excluding: own, in: transaction.database)
      let pending = try SyncPublishedTable.publishable(current: [first: late], hasPending: true, excluding: own, in: transaction.database)
      return (settled, pending)
    }

    #expect(published.0 == [first: early])
    #expect(published.1 == [first: early])
  }
}
