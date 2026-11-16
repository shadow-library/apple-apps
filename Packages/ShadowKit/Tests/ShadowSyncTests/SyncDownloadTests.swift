import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private let day: TimeInterval = 86_400

private func storedSegments(_ harness: SyncHarness) async throws -> [SyncStoredSegment] {
  try await harness.segments(of: harness.store.replica)
}

private func baseID(_ parts: [SealedFile]) throws -> SyncFileID {
  guard case .basePart(let replica, let upTo, let tag, _, _) = VaultPath.classify(try #require(parts.first).key) else { throw SyncFixtureFailure("not a base part") }
  return SyncFileID(replica: replica, kind: .base, point: StreamPoint(last: upTo, tag: tag))
}

private func put(_ files: [SealedFile], in provider: any StorageProvider) async throws {
  try await SyncPlant.put(files, in: provider)
}

private func noteLine(_ title: String) async throws -> Data {
  let scratch = try SyncFixture.open()
  try await scratch.write { transaction in _ = try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("fork")), ["title": .string(title)]) }
  return try #require(try await scratch.pendingChanges(limit: Int.max).last).line
}

private func referenceDigest(_ provider: any StorageProvider, ring: KeyRing) async throws -> String {
  try await SyncPlant.reference(in: provider, ring: ring)
}

@Suite("SyncEngine download")
struct SyncDownloadTests {
  @Test("should refuse to download before start has bootstrapped the replica")
  func shouldRefuseBeforeStart() async throws {
    let harness = SyncHarness(store: try SyncFixture.open(), provider: InMemoryStorageProvider())
    let error = await #expect(throws: SyncError.self) { try await harness.engine.download() }
    guard case .notStarted? = error else { throw SyncFixtureFailure("expected notStarted, got \(String(describing: error))") }
  }

  @Test("should apply another replica's segments, record them, converge, and fetch nothing on a second download")
  func shouldApplyAndConverge() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(3)
    let points = try await a.uploaded()

    let outcome = try await b.engine.download()

    #expect(outcome == SyncDownloadOutcome(applied: a.segmentIDs(points), held: [:], missingKeys: [:], reminted: false))
    #expect(try await b.appliedFiles()[a.store.replica]?.segments == Set(points))
    let gets = inner.callCounts.get
    #expect(try await b.engine.download().applied.isEmpty)
    #expect(inner.callCounts.get == gets)

    _ = try await b.engine.sync()
    _ = try await a.engine.download()
    let digests = (try await a.digest(), try await b.digest())
    #expect(digests.0 == digests.1)
    #expect(digests.0 == (try await referenceDigest(inner, ring: a.ring)))
  }

  @Test("should never download its own current prefix")
  func shouldSkipOwnPrefix() async throws {
    let inner = InMemoryStorageProvider()
    let harness = try await SyncHarness.started(provider: inner)
    try await harness.writeNotes(2)
    _ = try await harness.uploaded()
    let gets = inner.callCounts.get

    #expect(try await harness.engine.download() == SyncDownloadOutcome(applied: [], held: [:], missingKeys: [:], reminted: false))
    #expect(inner.callCounts.get == gets)
  }

  @Test("should hold a segment whose predecessor is not listed, without fetching it, for as many calls as it takes, then apply both in order")
  func shouldWaitForPredecessor() async throws {
    let hiding = SyncHidingProvider(wrapping: InMemoryStorageProvider())
    let peers = try await SyncPeers.make(2, provider: hiding)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(2)
    let first = try await a.uploaded()
    try await a.writeNotes(2, prefix: "m")
    let second = try await a.uploaded()
    let stored = try await storedSegments(a)
    hiding.hide(try #require(stored.first).key)
    let ids = a.segmentIDs(first + second)
    let gets = hiding.gets

    for _ in 0..<12 {
      let outcome = try await b.engine.download()
      #expect(outcome.applied.isEmpty)
      #expect(outcome.held == [ids[1]: .waitingForPredecessor])
    }
    #expect(hiding.gets == gets)

    hiding.reveal()
    #expect(try await b.engine.download().applied == ids)
  }

  @Test("should hold a segment until its dependency is applied, then apply it after the dependency")
  func shouldWaitForDependency() async throws {
    let hiding = SyncHidingProvider(wrapping: InMemoryStorageProvider())
    let peers = try await SyncPeers.make(3, provider: hiding)
    let (a, b, c) = (peers[0], peers[1], peers[2])
    try await a.writeNotes(2)
    let fromA = a.segmentIDs(try await a.uploaded())
    #expect(try await c.engine.download().applied == fromA)
    try await c.writeNotes(2, prefix: "c")
    let fromC = c.segmentIDs(try await c.uploaded())
    hiding.hide(VaultPath.replicaPrefix(a.store.replica))

    let waiting = try await b.engine.download()
    #expect(waiting.applied.isEmpty)
    #expect(waiting.held == [fromC[0]: .waitingForDependency(a.store.replica)])
    #expect(try await b.heldFiles()[fromC[0]]?.waits == 1)

    hiding.reveal()
    #expect(try await b.engine.download().applied == fromA + fromC)
    #expect(try await b.heldFiles().isEmpty)
  }

  @Test("should apply a segment anyway after it waited the configured number of calls for a dependency that never appears")
  func shouldStopWaitingForVanishedDependency() async throws {
    let hiding = SyncHidingProvider(wrapping: InMemoryStorageProvider())
    let peers = try await SyncPeers.make(3, provider: hiding)
    let (a, b, c) = (peers[0], peers[1], peers[2])
    try await a.writeNotes(1)
    _ = try await a.uploaded()
    _ = try await c.engine.download()
    try await c.writeNotes(1, prefix: "c")
    let fromC = c.segmentIDs(try await c.uploaded())
    hiding.hide(VaultPath.replicaPrefix(a.store.replica))

    for call in 1..<SyncConfiguration().dependencyWaitCalls {
      let outcome = try await b.engine.download()
      #expect(outcome.applied.isEmpty, "call \(call)")
      #expect(try await b.heldFiles()[fromC[0]]?.waits == call)
    }
    #expect(try await b.engine.download().applied == fromC)
    #expect(try await b.heldFiles().isEmpty)
  }

  @Test("should record a file as applied in the transaction that applied it, so a crash right after does not apply it again")
  func shouldRecordInApplyingTransaction() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(2)
    let points = try await a.uploaded()
    let crashing = SyncHarness(
      store: b.store, provider: inner, keychain: peers.keychain, device: "peer1", trustedClock: b.trustedClock, downloadCrashAt: .applied)
    _ = try await crashing.engine.start()

    let error = await #expect(throws: SyncError.self) { try await crashing.engine.download() }
    guard case .corruptState("injected crash")? = error else { throw SyncFixtureFailure("expected the injected crash, got \(String(describing: error))") }

    #expect(try await b.appliedFiles()[a.store.replica]?.segments == Set(points))
    let gets = inner.callCounts.get
    #expect(try await b.engine.download().applied.isEmpty)
    #expect(inner.callCounts.get == gets)
  }
}

@Suite("SyncEngine download of bases")
struct SyncDownloadBaseTests {
  @Test("should join from a base and then apply the segments after it when the covered segments are gone")
  func shouldJoinFromBase() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    let replica = a.store.replica
    try await a.writeNotes(3)
    let first = try await a.uploaded()
    let parts = try await SyncPlant.base(of: a, through: first.last)
    try await put(parts, in: inner)
    let covered = try await storedSegments(a).map(\.key)
    try await a.writeNotes(2, prefix: "m")
    let second = try await a.uploaded()
    try await inner.delete(covered)

    let outcome = try await b.engine.download()

    #expect(a.store.replica == replica)
    #expect(outcome.applied == [try baseID(parts)] + a.segmentIDs(second))
    #expect(outcome.held.isEmpty)
    _ = try await b.engine.sync()
    _ = try await a.engine.download()
    #expect(try await a.digest() == (try await b.digest()))
  }

  @Test("should hold a base with a missing part and apply it once every part is listed")
  func shouldWaitForEveryPart() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    let replica = a.store.replica
    try await a.writeNotes(6) { "A title long enough to need several base parts \($0)" }
    let first = try await a.uploaded()
    let parts = try await SyncPlant.base(of: a, through: first.last, partPayloadBytes: 1_000)
    #expect(parts.count >= 3)
    try await put(parts.enumerated().filter { $0.offset != 1 }.map(\.element), in: inner)
    try await inner.delete(try await storedSegments(a).map(\.key))
    try await a.writeNotes(1, prefix: "m")
    let second = a.segmentIDs(try await a.uploaded())
    let base = try baseID(parts)

    let waiting = try await b.engine.download()

    #expect(a.store.replica == replica)
    #expect(waiting.applied.isEmpty)
    #expect(waiting.held == [base: .incompleteBase(missing: [2]), second[0]: .waitingForPredecessor])

    try await put([parts[1]], in: inner)
    #expect(try await b.engine.download().applied == [base] + second)
  }

  @Test("should still apply a segment a base covers, so a second writer under the same id loses nothing")
  func shouldNotSkipCoveredSegment() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(3)
    let first = try await a.uploaded()
    let parts = try await SyncPlant.base(of: a, through: first.last)
    try await put(parts, in: inner)
    try await inner.delete(try await storedSegments(a).map(\.key))
    let key = try #require(a.ring.writingKey())
    let fork = try await SyncPlant.segment([try await noteLine("from the other writer")], replica: a.store.replica, key: key, in: inner)
    let forkID = SyncFileID(replica: a.store.replica, kind: .segment, point: StreamPoint(last: 1, tag: fork.tag))

    let outcome = try await b.engine.download()

    #expect(outcome.applied == [try baseID(parts), forkID])
    let note = try await b.store.read { try $0.state(of: EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("fork"))) }
    guard case .record(let record)? = note else { throw SyncFixtureFailure("the second writer's note did not arrive") }
    #expect(record[field: "title"]?.value == .string("from the other writer"))
  }
}

@Suite("SyncEngine download of unusable files")
struct SyncDownloadUnusableTests {
  @Test("should hold a segment sealed with a key it lacks, report the key, not fetch it again, and apply it once the key arrives")
  func shouldWaitForKey() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner, sharedKey: false)
    let (a, b) = (peers[0], peers[1])
    let keyA = try #require(a.ring.keyIDs.first)
    try await a.writeNotes(2)
    let ids = a.segmentIDs(try await a.uploaded())
    let gets = inner.callCounts.get

    let held = try await b.engine.download()

    #expect(held.applied.isEmpty)
    #expect(held.held == [ids[0]: .missingKey(keyA)])
    #expect(held.missingKeys == [keyA: [a.store.replica]])
    #expect(inner.callCounts.get == gets + 1)
    #expect(try await b.engine.download() == held)
    #expect(inner.callCounts.get == gets + 1)

    peers.keychain.deliver()
    let applied = try await b.engine.download()
    #expect(applied.applied == ids && applied.missingKeys.isEmpty)
  }

  @Test("should retry a segment that fails authentication, reject it after the configured calls while other replicas apply, and retry when its size changes")
  func shouldRejectUnauthenticated() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(3, provider: inner)
    let (a, b, c) = (peers[0], peers[1], peers[2])
    try await a.writeNotes(2)
    let fromA = a.segmentIDs(try await a.uploaded())
    let stored = try #require(try await storedSegments(a).first)
    _ = try await inner.put(stored.key, data: stored.data.dropLast(), condition: .overwrite)
    try await c.writeNotes(1, prefix: "c")
    let fromC = c.segmentIDs(try await c.uploaded())
    let attempts = SyncConfiguration().unreadableFileAttempts

    for call in 1...attempts {
      let outcome = try await b.engine.download()
      #expect(outcome.applied == (call == 1 ? fromC : []))
      #expect(outcome.held == [fromA[0]: call < attempts ? .unauthenticated : .rejected], "call \(call)")
    }
    let gets = inner.callCounts.get
    #expect(try await b.engine.download().held == [fromA[0]: .rejected])
    #expect(inner.callCounts.get == gets)

    _ = try await inner.put(stored.key, data: stored.data, condition: .overwrite)
    #expect(try await b.engine.download().applied == fromA)
  }

  @Test("should hold an authentic but malformed segment, reject it after the configured calls, and retry when its size changes")
  func shouldRejectMalformed() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(1)
    let fromA = a.segmentIDs(try await a.uploaded())
    let key = try #require(a.ring.writingKey())
    let foreign = ReplicaID(UUID.v7())
    let objectKey = VaultPath.segment(foreign, first: 1, last: 1, tag: ReplicaFixture.tag(7))
    let id = SyncFileID(replica: foreign, kind: .segment, point: ReplicaFixture.point(1, 7))
    _ = try await inner.put(objectKey, data: try CodecFrame.seal(Data("not a segment\n".utf8), at: objectKey, vault: SyncFixture.vault, with: key), condition: .overwrite)
    let attempts = SyncConfiguration().unreadableFileAttempts

    for call in 1...attempts {
      let outcome = try await b.engine.download()
      #expect(outcome.applied == (call == 1 ? fromA : []))
      #expect(outcome.held == [id: call < attempts ? .malformed : .rejected], "call \(call)")
    }

    let longer = try CodecFrame.seal(Data("still not a segment, but longer\n".utf8), at: objectKey, vault: SyncFixture.vault, with: key)
    _ = try await inner.put(objectKey, data: longer, condition: .overwrite)
    #expect(try await b.engine.download().held == [id: .malformed])
    #expect(try await b.heldFiles()[id]?.attempts == 1)
  }

  @Test("should hold a segment stamped two days ahead and everything chained after it while other replicas apply, until the reader's clock passes it", arguments: [false, true])
  func shouldHoldFutureSegment(reportsServerTime: Bool) async throws {
    let startClock: @Sendable () -> Date = { SyncFixture.start }
    let provider = InMemoryStorageProvider(serverClock: reportsServerTime ? startClock : nil)
    let readerClock = SyncSettableClock(SyncFixture.start)
    let peers = try await SyncPeers.make(2, provider: provider, clocks: [readerClock, readerClock])
    let (b, c) = (peers[0], peers[1])
    let ahead = SyncFixture.start.addingTimeInterval(2 * day)
    let writerStorage = InMemoryStorageProvider()
    let writerClock = TrustedClock(wallClock: { ahead }, monotonic: SyncFixedMonotonic())
    let a = SyncHarness(
      store: try SyncFixture.open(wallClock: SyncEngine.wallClock(preferring: writerClock) { ahead }), provider: writerStorage, keychain: peers.keychain,
      device: "writer", trustedClock: writerClock, wallClock: { ahead })
    peers.keychain.deliver()
    _ = try await a.engine.start()
    try await a.writeNotes(2)
    let first = try await a.uploaded()
    try await a.writeNotes(1, prefix: "m")
    let fromA = a.segmentIDs(first + (try await a.uploaded()))
    for object in try await writerStorage.listAll(prefix: "") {
      _ = try await provider.put(object.key, data: try await writerStorage.get(object.key), condition: .overwrite)
    }
    try await c.writeNotes(1, prefix: "c")
    let fromC = c.segmentIDs(try await c.uploaded())
    if reportsServerTime {
      b.trustedClock.record(serverDate: SyncFixture.start)
      readerClock.set(SyncFixture.start.addingTimeInterval(10 * day))
    }

    let held = try await b.engine.download()

    #expect(held.applied == fromC)
    #expect(held.held == [fromA[0]: SyncHoldReason.clockAhead, fromA[1]: .waitingForPredecessor])
    #expect(try await b.engine.download().held == held.held)

    let passed = SyncFixture.start.addingTimeInterval(day + 3_600)
    if reportsServerTime {
      for _ in 0..<3 { b.trustedClock.record(serverDate: passed) }
    } else {
      readerClock.set(passed)
    }
    let released = try await b.engine.download()
    #expect(released.applied == fromA && released.held.isEmpty)
  }
}

@Suite("SyncEngine download identity")
struct SyncDownloadIdentityTests {
  @Test("should re-mint once when a foreign file carries its own replica id, then download its former prefix and converge")
  func shouldRemintOnCollision() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    try await b.writeNotes(2)
    let fromOld = b.segmentIDs(try await b.uploaded())
    let old = b.store.replica
    let line = try #require(try await storedSegments(b).first?.file.lines.last)
    let foreign = ReplicaID(UUID.v7())
    let planted = try await SyncPlant.segment([line], replica: foreign, key: try #require(b.ring.writingKey()), in: inner)
    let plantedID = SyncFileID(replica: foreign, kind: .segment, point: StreamPoint(last: 1, tag: planted.tag))

    let outcome = try await b.engine.download()

    #expect(outcome.reminted && b.store.replica != old)
    #expect(Set(outcome.applied) == Set(fromOld + [plantedID]) && outcome.held.isEmpty)
    let replica = b.store.replica
    #expect(try await !b.engine.download().reminted)
    #expect(b.store.replica == replica)

    try await peers.settle()
    #expect(try await a.digest() == (try await b.digest()))
    #expect(try await a.lifecycle.directory().isRetired(old))
  }

  @Test("should re-apply everything, its own former prefix included, after a clock-corrected rebuild")
  func shouldRejoinAfterRebuild() async throws {
    let directory = ReplicaTemporaryDirectory()
    let location = StoreLocation.file(directory.database("b"))
    let provider = InMemoryStorageProvider(serverClock: { SyncFixture.start })
    let keychain = InMemoryKeychain()
    let aClock = TrustedClock(wallClock: { SyncFixture.start }, monotonic: SyncFixedMonotonic())
    let a = SyncHarness(
      store: try SyncFixture.open(wallClock: SyncEngine.wallClock(preferring: aClock) { SyncFixture.start }), provider: provider, keychain: keychain, device: "a",
      trustedClock: aClock)
    _ = try a.ring.createKey()
    _ = try await a.engine.start()
    let beforeClock = TrustedClock(wallClock: { SyncFixture.start }, monotonic: SyncFixedMonotonic())
    let before = SyncHarness(
      store: try SyncFixture.open(location, wallClock: SyncEngine.wallClock(preferring: beforeClock) { SyncFixture.start }), provider: provider, keychain: keychain,
      device: "b", trustedClock: beforeClock)
    keychain.deliver()
    _ = try await before.engine.start()
    try await a.writeNotes(2)
    _ = try await a.uploaded()
    try await before.writeNotes(2, prefix: "b")
    _ = try await before.engine.sync()
    let old = before.store.replica

    let yearAhead = SyncFixture.start.addingTimeInterval(365 * day)
    let restartedClock = TrustedClock(wallClock: { yearAhead }, monotonic: SyncFixedMonotonic())
    let b = SyncHarness(
      store: try SyncFixture.open(location, wallClock: SyncEngine.wallClock(preferring: restartedClock) { yearAhead }), provider: provider, keychain: keychain,
      device: "b", trustedClock: restartedClock, wallClock: { yearAhead })
    _ = try await b.engine.start()
    try await b.writeNotes(1, prefix: "late")
    _ = try await b.uploaded()
    #expect(b.store.replica != old)
    #expect(try await b.appliedFiles().isEmpty)

    let outcome = try await b.engine.download()

    #expect(Set(outcome.applied.map(\.replica)) == [a.store.replica, old])
    for _ in 0..<3 {
      _ = try await a.engine.sync()
      _ = try await b.engine.sync()
    }
    let reference = try await referenceDigest(provider, ring: a.ring)
    #expect(try await b.digest() == reference)
    #expect(try await a.digest() == reference)
  }

  @Test("should raise the saved floors from downloaded floor records and refuse the next download and upload when the vault needs a newer schema")
  func shouldRaiseFloorsFromDownload() async throws {
    let newer = SyncKernelSchema.registry(version: SyncFixture.registry.version + 1, adding: SyncFixture.entities)
    let peers = try await SyncPeers.make(2, registries: [newer, SyncFixture.registry])
    let (a, b) = (peers[0], peers[1])
    let key = try #require(a.ring.keyIDs.first)
    try await a.raiseDirectoryFloors(key: key, schema: newer.version)
    _ = try await a.uploaded()

    let outcome = try await b.engine.download()

    #expect(!outcome.applied.isEmpty)
    #expect(try await b.savedFloors() == SyncFloors(key: key, schema: newer.version))
    for attempt in 0..<2 {
      let error = await #expect(throws: SyncError.self) {
        if attempt == 0 { _ = try await b.engine.download() } else { _ = try await b.engine.upload() }
      }
      guard case .appUpdateRequired(newer.version, SyncFixture.registry.version)? = error else {
        throw SyncFixtureFailure("expected appUpdateRequired, got \(String(describing: error))")
      }
    }
  }
}
