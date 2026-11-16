import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private func baseID(_ parts: [SealedFile]) throws -> SyncFileID {
  guard case .basePart(let replica, let upTo, let tag, _, _) = VaultPath.classify(try #require(parts.first).key) else { throw SyncFixtureFailure("not a base part") }
  return SyncFileID(replica: replica, kind: .base, point: StreamPoint(last: upTo, tag: tag))
}

private func noteLines(_ titles: [String], keyPrefix: String) async throws -> [Data] {
  let scratch = try SyncFixture.open()
  try await scratch.write { transaction in
    for (index, title) in titles.enumerated() {
      _ = try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("\(keyPrefix)\(index)")), ["title": .string(title)])
    }
  }
  return try await scratch.pendingChanges(limit: Int.max).map(\.line).suffix(titles.count)
}

private func segmentFile(_ lines: [Data], replica: ReplicaID, first: Int64 = 1) throws -> SegmentFile {
  guard let header = SegmentHeader(replica: replica, first: first, last: first + Int64(lines.count) - 1, previous: nil, dependencies: [:], schema: 3),
    let file = SegmentFile(header: header, lines: lines)
  else { throw SyncFixtureFailure("the segment is invalid") }
  return file
}

private func sealBase(_ lines: [Data], replica: ReplicaID, upTo: Int64, key: VaultKey) throws -> [SealedFile] {
  guard let header = BaseHeader(replica: replica, upTo: upTo, through: nil, schema: 3), let file = BaseFile(header: header, lines: lines) else {
    throw SyncFixtureFailure("the base is invalid")
  }
  return try BaseCodec.seal(file, vault: SyncFixture.vault, with: key)
}

private func title(of key: String, in harness: SyncHarness) async throws -> JSONValue? {
  let state = try await harness.store.read { try $0.state(of: EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key(key))) }
  guard case .record(let record)? = state else { return nil }
  return record[field: "title"]?.value
}

private func expectConverged(_ peers: SyncPeers, _ inner: InMemoryStorageProvider) async throws {
  try await peers.settle()
  let reference = try await SyncPlant.reference(in: inner, ring: peers[0].ring)
  for peer in peers.peers { #expect(try await peer.digest() == reference) }
}

@Suite("SyncEngine download of every base")
struct SyncDownloadBaseLossTests {
  @Test("should apply a base covering segments it never saw after their writer compacted them away")
  func shouldApplyBaseAfterCompaction() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(2)
    let first = a.segmentIDs(try await a.uploaded())
    #expect(try await b.engine.download().applied == first)
    try await a.writeNotes(2, prefix: "m")
    _ = try await a.uploaded()
    let parts = try await SyncPlant.compact(a, in: inner)
    #expect(try await inner.listAll(prefix: VaultPath.segmentPrefix(a.store.replica)).isEmpty)

    let outcome = try await b.engine.download()

    #expect(outcome.applied == [try baseID(parts)] && outcome.held.isEmpty)
    #expect(try await title(of: "m1", in: b) == .string("Title 1"))
    try await expectConverged(peers, inner)
  }

  @Test("should apply both bases of two writers that shared a replica id when no segment is left")
  func shouldApplyEveryWritersBase() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let b = peers[1]
    let key = try #require(peers[0].ring.writingKey())
    let shared = ReplicaID(UUID.v7())
    let first = try sealBase(try await noteLines(["one", "two", "three", "four"], keyPrefix: "w"), replica: shared, upTo: 4, key: key)
    let second = try sealBase(try await noteLines(["the other writer"], keyPrefix: "other"), replica: shared, upTo: 1, key: key)
    try await SyncPlant.put(first + second, in: inner)

    let outcome = try await b.engine.download()

    #expect(outcome.applied == [try baseID(second), try baseID(first)])
    #expect(try await title(of: "other0", in: b) == .string("the other writer"))
    #expect(try await title(of: "w3", in: b) == .string("four"))
    try await expectConverged(peers, inner)
  }

  @Test("should apply an older and a newer base of one replica, each once")
  func shouldApplyOlderAndNewerBase() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(2)
    _ = try await a.uploaded()
    let older = try await SyncPlant.compact(a, in: inner)
    try await a.writeNotes(2, prefix: "m")
    _ = try await a.uploaded()
    let newer = try await SyncPlant.compact(a, in: inner)

    #expect(try await b.engine.download().applied == [try baseID(older), try baseID(newer)])
    let gets = inner.callCounts.get
    #expect(try await b.engine.download().applied.isEmpty)
    #expect(inner.callCounts.get == gets)
    try await expectConverged(peers, inner)
  }

  @Test("should fetch, apply and record a base once although every segment it covers was applied before")
  func shouldApplyBaseOverAppliedSegments() async throws {
    let hiding = SyncHidingProvider(wrapping: InMemoryStorageProvider())
    let peers = try await SyncPeers.make(2, provider: hiding)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(3)
    let first = try await a.uploaded()
    #expect(try await b.engine.download().applied == a.segmentIDs(first))
    let parts = try await SyncPlant.base(of: a, through: first.last)
    try await SyncPlant.put(parts, in: hiding)
    let base = try baseID(parts)

    #expect(try await b.engine.download().applied == [base])
    #expect(try await b.engine.download().applied.isEmpty)

    #expect(parts.allSatisfy { hiding.gets(of: $0.key) == 1 })
    #expect(try await b.appliedFiles()[a.store.replica]?.bases == [base.point])
    _ = try await b.engine.sync()
    _ = try await a.engine.download()
    #expect(try await a.digest() == (try await b.digest()))
  }

  @Test("should hold a fork whose header predecessor is not listed although a segment with the same end is applied")
  func shouldHoldForkUntilItsOwnPredecessor() async throws {
    let inner = InMemoryStorageProvider()
    let peers = try await SyncPeers.make(2, provider: inner)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(2)
    let first = try await a.uploaded()
    let end = try #require(first.last).last
    #expect(try await b.engine.download().applied == a.segmentIDs(first))
    let key = try #require(a.ring.writingKey())
    let otherLines = try await noteLines((1...Int(end)).map { "other \($0)" }, keyPrefix: "o")
    let otherFile = try segmentFile(otherLines, replica: a.store.replica)
    let other = try SegmentCodec.seal(otherFile, vault: SyncFixture.vault, with: key)
    let fork = try await SyncPlant.segment(
      try await noteLines(["after the other writer"], keyPrefix: "f"), replica: a.store.replica, first: end + 1, previous: StreamPoint(last: end, tag: other.tag), key: key,
      in: inner)
    let forkID = SyncFileID(replica: a.store.replica, kind: .segment, point: StreamPoint(last: end + 1, tag: fork.tag))
    let otherID = SyncFileID(replica: a.store.replica, kind: .segment, point: StreamPoint(last: end, tag: other.tag))

    let waiting = try await b.engine.download()
    #expect(waiting.applied.isEmpty)
    #expect(waiting.held == [forkID: .waitingForPredecessor])

    _ = try await inner.put(other.key, data: other.data, condition: .overwrite)
    #expect(try await b.engine.download().applied == [otherID, forkID])
    _ = try await b.engine.sync()
    #expect(try await b.digest() == (try await SyncPlant.reference(in: inner, ring: b.ring)))
  }
}

@Suite("SyncEngine download of files it cannot use yet")
struct SyncDownloadLaterTests {
  @Test("should hold a file in a newer format without ever rejecting it, fetching it once per engine instance, while its successors wait and others apply")
  func shouldHoldUnsupportedFormat() async throws {
    let hiding = SyncHidingProvider(wrapping: InMemoryStorageProvider())
    let peers = try await SyncPeers.make(2, provider: hiding)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(1)
    let fromA = a.segmentIDs(try await a.uploaded())
    let key = try #require(a.ring.writingKey())
    let newer = ReplicaID(UUID.v7())
    let firstFile = try segmentFile(try await noteLines(["new"], keyPrefix: "x"), replica: newer)
    let sealed = try SegmentCodec.seal(firstFile, vault: SyncFixture.vault, with: key)
    var future = sealed.data
    future[future.startIndex + 4] = VaultFormat.version + 1
    _ = try await hiding.put(sealed.key, data: future, condition: .overwrite)
    let next = try await SyncPlant.segment(
      try await noteLines(["after"], keyPrefix: "y"), replica: newer, first: 2, previous: StreamPoint(last: 1, tag: sealed.tag), key: key, in: hiding)
    let unsupportedID = SyncFileID(replica: newer, kind: .segment, point: StreamPoint(last: 1, tag: sealed.tag))
    let nextID = SyncFileID(replica: newer, kind: .segment, point: StreamPoint(last: 2, tag: next.tag))

    for call in 1...(2 * SyncConfiguration().unreadableFileAttempts) {
      let outcome = try await b.engine.download()
      #expect(outcome.applied == (call == 1 ? fromA : []))
      #expect(outcome.held == [unsupportedID: .unsupported, nextID: .waitingForPredecessor], "call \(call)")
    }
    #expect(hiding.gets(of: sealed.key) == 1 && hiding.gets(of: next.key) == 0)

    let restarted = SyncHarness(store: b.store, provider: hiding, keychain: peers.keychain, device: "peer1", trustedClock: b.trustedClock)
    _ = try await restarted.engine.start()
    #expect(try await restarted.engine.download().held[unsupportedID] == .unsupported)
    #expect(try await restarted.engine.download().held[unsupportedID] == .unsupported)
    #expect(hiding.gets(of: sealed.key) == 2)

    _ = try await b.engine.sync()
    _ = try await a.engine.download()
    #expect(try await a.digest() == (try await b.digest()))
  }

  @Test("should hold one object storage cannot deliver, apply every other file in the same call, and apply it once the fault clears")
  func shouldHoldUndeliverableObject() async throws {
    let hiding = SyncHidingProvider(wrapping: InMemoryStorageProvider())
    let peers = try await SyncPeers.make(3, provider: hiding)
    let (a, b, c) = (peers[0], peers[1], peers[2])
    try await a.writeNotes(2)
    let fromA = a.segmentIDs(try await a.uploaded())
    let broken = try #require(try await a.segments(of: a.store.replica).first).key
    try await c.writeNotes(1, prefix: "c")
    let fromC = c.segmentIDs(try await c.uploaded())
    hiding.fail(broken, with: .underlying("checksum mismatch"))
    let gets = hiding.gets(of: broken)

    var fetchedOn: [Int] = []
    for call in 0..<11 {
      let before = hiding.gets(of: broken)
      let outcome = try await b.engine.download()
      #expect(outcome.held == [fromA[0]: .unavailable])
      #expect(outcome.applied == (call == 0 ? fromC : []))
      if hiding.gets(of: broken) > before { fetchedOn.append(call) }
    }
    #expect(fetchedOn == [0, 1, 2, 10])
    #expect(hiding.gets(of: broken) == gets + 4)
    #expect(try await b.appliedFiles()[c.store.replica]?.segments == Set(fromC.map(\.point)))

    hiding.fail(broken, with: nil)
    var calls = 0
    var applied: [SyncFileID] = []
    while applied.isEmpty, calls <= SyncDownloadSession.unavailableRetryInterval {
      calls += 1
      applied = try await b.engine.download().applied
    }
    #expect(applied == fromA)
    #expect(calls == SyncDownloadSession.unavailableRetryInterval)
    #expect(hiding.gets(of: broken) == gets + 5)
    try await peers.settle()
    let digests = try await [a.digest(), b.digest(), c.digest()]
    #expect(Set(digests).count == 1)
  }

  @Test("should end the call when the provider itself is unavailable")
  func shouldStopOnProviderFailure() async throws {
    let hiding = SyncHidingProvider(wrapping: InMemoryStorageProvider())
    let peers = try await SyncPeers.make(2, provider: hiding)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(1)
    _ = try await a.uploaded()
    hiding.fail(try #require(try await a.segments(of: a.store.replica).first).key, with: .rateLimited(retryAfter: nil))

    let error = await #expect(throws: SyncError.self) { try await b.engine.download() }
    guard case .storage(.rateLimited)? = error else { throw SyncFixtureFailure("expected the provider failure, got \(String(describing: error))") }
  }

  @Test("should return a postponed outcome, not an error, when the marker cannot be read to re-mint after a collision")
  func shouldPostponeCollisionRemint() async throws {
    let inner = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let marker = SyncFlakySecureStore(wrapping: keychain.device("b").store(service: "marker", scope: .device))
    let b = SyncHarness(store: try SyncFixture.open(), provider: inner, keychain: keychain, device: "b", markerStore: marker)
    _ = try b.ring.createKey()
    _ = try await b.engine.start()
    try await b.writeNotes(1)
    _ = try await b.uploaded()
    let old = b.store.replica
    let line = try #require(try await b.segments(of: old).first?.file.lines.last)
    _ = try await SyncPlant.segment([line], replica: ReplicaID(UUID.v7()), key: try #require(b.ring.writingKey()), in: inner)
    marker.failReads(after: 0)

    let postponed = try await b.engine.download()

    #expect(postponed.postponed && !postponed.reminted && b.store.replica == old)
    marker.heal()
    let resumed = try await b.engine.download()
    #expect(!resumed.postponed && resumed.reminted && b.store.replica != old)
  }

  @Test("should keep a rejected file's count while a stale listing omits it, and forget it after the retention calls")
  func shouldKeepRowsAcrossStaleListing() async throws {
    let inner = InMemoryStorageProvider()
    let hiding = SyncHidingProvider(wrapping: inner)
    let peers = try await SyncPeers.make(2, provider: hiding)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(1)
    let fromA = a.segmentIDs(try await a.uploaded())
    let stored = try #require(try await a.segments(of: a.store.replica).first)
    _ = try await inner.put(stored.key, data: stored.data.dropLast(), condition: .overwrite)
    for _ in 1...SyncConfiguration().unreadableFileAttempts { _ = try await b.engine.download() }
    #expect(try await b.heldFiles()[fromA[0]]?.reason == .rejected)

    hiding.hide(stored.key)
    for _ in 0..<3 { #expect(try await b.engine.download().held.isEmpty) }
    hiding.reveal()
    let gets = hiding.gets(of: stored.key)
    #expect(try await b.engine.download().held == [fromA[0]: .rejected])
    #expect(hiding.gets(of: stored.key) == gets)

    hiding.hide(stored.key)
    for _ in 0...SyncDownloadSession.unlistedCallsKept { _ = try await b.engine.download() }
    #expect(try await b.heldFiles()[fromA[0]] == nil)
    _ = try await inner.put(stored.key, data: stored.data, condition: .overwrite)
    hiding.reveal()
    #expect(try await b.engine.download().applied == fromA)
    _ = try await b.engine.sync()
    _ = try await a.engine.download()
    #expect(try await a.digest() == (try await b.digest()))
  }

  @Test("should round-trip every hold reason through the held table and read an unknown one as no row")
  func shouldDecodeReasons() async throws {
    let harness = try await SyncHarness.started()
    let reasons: [SyncHoldReason] = [
      .missingKey(SyncFixture.keyID(1)), .unauthenticated, .malformed, .clockAhead, .waitingForPredecessor, .waitingForDependency(ReplicaID(UUID.v7())),
      .incompleteBase(missing: [2, 5]), .rejected, .unsupported, .unavailable,
    ]
    let files = reasons.enumerated().map { index, reason in
      SyncHeldFile(
        id: SyncFileID(replica: ReplicaID(UUID.v7()), kind: .segment, point: ReplicaFixture.point(Int64(index + 1), index)), size: index, reason: reason, clock: nil,
        attempts: index, waits: index, unlisted: index)
    }
    try await harness.store.write { transaction in try SyncHeldTable.replace(with: files, in: transaction.database) }

    #expect(try await harness.heldFiles() == Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) }))
    #expect(SyncHeldTable.reason("from-a-newer-app", detail: nil) == nil)
  }

  @Test("should restart the dependency wait count when the replica a segment waits on changes")
  func shouldResetWaitsPerDependency() async throws {
    let inner = InMemoryStorageProvider()
    let hiding = SyncHidingProvider(wrapping: inner)
    let peers = try await SyncPeers.make(4, provider: hiding)
    let (a, b, c, d) = (peers[0], peers[1], peers[2], peers[3])
    for (index, writer) in [a, d].enumerated() {
      try await writer.writeNotes(1, prefix: "w\(index)-")
      _ = try await writer.uploaded()
    }
    _ = try await c.engine.download()
    try await c.writeNotes(1, prefix: "c")
    let fromC = c.segmentIDs(try await c.uploaded())
    let (first, second) = a.store.replica < d.store.replica ? (a, d) : (d, a)
    hiding.hide(VaultPath.replicaPrefix(a.store.replica))
    hiding.hide(VaultPath.replicaPrefix(d.store.replica))

    #expect(try await b.engine.download().held[fromC[0]] == .waitingForDependency(first.store.replica))
    #expect(try await b.engine.download().held[fromC[0]] == .waitingForDependency(first.store.replica))
    #expect(try await b.heldFiles()[fromC[0]]?.waits == 2)

    hiding.reveal()
    hiding.hide(VaultPath.replicaPrefix(second.store.replica))
    #expect(try await b.engine.download().held[fromC[0]] == .waitingForDependency(second.store.replica))
    #expect(try await b.heldFiles()[fromC[0]]?.waits == 1)

    hiding.reveal()
    #expect(try await b.engine.download().applied.contains(fromC[0]))
    try await peers.settle()
    let digests = try await [a.digest(), b.digest(), c.digest(), d.digest()]
    #expect(Set(digests).count == 1)
  }
}
