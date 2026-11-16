import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private func settings(files: Int = .max, bytes: Int = .max, age: Int = 15, interval: Int = 30, partBytes: Int = BaseCodec.defaultPartPayloadBytes) -> SyncConfiguration {
  SyncConfiguration(
    maximumSegmentLines: 100, compactionAge: SyncDays.duration(age), compactionBytes: bytes, compactionFiles: files, compactionInterval: SyncDays.duration(interval),
    basePartBytes: partBytes)
}

private struct SyncWriter {
  let world: SyncCompactWorld
  let store: VaultStore
  let provider: SyncCompactProvider
  var harness: SyncHarness

  static func make(_ world: SyncCompactWorld, _ configuration: SyncConfiguration) async throws -> SyncWriter {
    let store = try world.openStore()
    let provider = SyncCompactProvider(wrapping: world.storage)
    let harness = try await world.started(world.harness("writer", store: store, provider: provider, configuration: configuration), createsKey: true)
    return SyncWriter(world: world, store: store, provider: provider, harness: harness)
  }

  var replica: ReplicaID { store.replica }

  /// A new engine instance on the same database, as after an app restart with other settings.
  mutating func restart(_ configuration: SyncConfiguration) async throws {
    harness = world.harness("writer", store: store, provider: provider, configuration: configuration)
    #expect(try await harness.engine.start() == .alreadyRunning)
  }

  func upload(_ count: Int, prefix: String) async throws -> [StreamPoint] {
    try await harness.writeNotes(count, prefix: prefix)
    return try await harness.uploaded()
  }

  func expectOwnDeletes() async throws {
    #expect(try await SyncCompactCheck.ownDeletes(provider.deleted, by: store).isEmpty)
  }
}

/// Change lines written by a replica that is not the writer, as another device or an adopted replica would hold them.
private func foreignLines(_ count: Int, prefix: String) async throws -> [Data] {
  let scratch = try SyncFixture.open()
  try await scratch.write { transaction in
    for index in 0..<count { _ = try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("\(prefix)\(index)")), ["title": .string("\(prefix) \(index)")]) }
  }
  return Array(try await scratch.pendingChanges(limit: Int.max).map(\.line).suffix(count))
}

private func basePuts(_ provider: SyncCompactProvider) -> [ObjectKey] {
  provider.puts.filter {
    guard case .basePart = VaultPath.classify($0) else { return false }
    return true
  }
}

@Suite("SyncEngine compaction decision")
struct SyncCompactDecisionTests {
  @Test("should write nothing below both thresholds")
  func shouldWriteNothingBelowThresholds() async throws {
    let world = SyncCompactWorld()
    let writer = try await SyncWriter.make(world, settings(files: 4))
    for batch in 0..<3 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 20)

    #expect(try await writer.harness.engine.compact() == .notNeeded)

    #expect(basePuts(writer.provider).isEmpty)
    #expect(writer.provider.deleted.isEmpty)
    #expect(try await SyncCompactCheck.entries(writer.harness).allSatisfy { !$0.isBase })
  }

  @Test("should compact when either the file count or the byte total of old segments is reached", arguments: [true, false])
  func shouldCompactOnEitherThreshold(byFiles: Bool) async throws {
    let world = SyncCompactWorld()
    var writer = try await SyncWriter.make(world, settings())
    for batch in 0..<3 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 20)
    let stored = try await world.storage.listAll(prefix: VaultPath.segmentPrefix(writer.replica))
    let bytes = stored.map(\.size).reduce(0, +)
    #expect(stored.count == 3)

    try await writer.restart(settings(files: 4, bytes: bytes + 1))
    #expect(try await writer.harness.engine.compact() == .notNeeded)
    try await writer.restart(byFiles ? settings(files: 3) : settings(bytes: bytes))
    let outcome = try await writer.harness.engine.compact()

    guard case .compacted(_, let deletedSegments, 0) = outcome else { throw SyncFixtureFailure("expected a base, got \(outcome)") }
    #expect(deletedSegments == 3)
    try await writer.expectOwnDeletes()
  }

  @Test("should count a segment the listing omits as zero bytes")
  func shouldCountUnlistedSegmentAsEmpty() async throws {
    let world = SyncCompactWorld()
    var writer = try await SyncWriter.make(world, settings())
    for batch in 0..<3 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 20)
    let bytes = try await world.storage.listAll(prefix: VaultPath.segmentPrefix(writer.replica)).map(\.size).reduce(0, +)
    try await writer.restart(settings(bytes: bytes))
    writer.provider.hide(VaultPath.segmentPrefix(writer.replica))

    #expect(try await writer.harness.engine.compact() == .notNeeded)
  }

  @Test("should not make a second base within the interval, and make one once it has passed")
  func shouldRespectInterval() async throws {
    let world = SyncCompactWorld()
    let writer = try await SyncWriter.make(world, settings(files: 1))
    for batch in 0..<3 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 20)
    guard case .compacted(let first, _, _) = try await writer.harness.engine.compact() else { throw SyncFixtureFailure("expected a first base") }
    for batch in 3..<5 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 20)

    #expect(try await writer.harness.engine.compact() == .notNeeded)
    world.advance(days: 11)
    let outcome = try await writer.harness.engine.compact()

    guard case .compacted(let second, 2, 1) = outcome else { throw SyncFixtureFailure("expected a second base, got \(outcome)") }
    #expect(second.last > first.last)
    let stored = try await SyncStoredFiles.read(writer.replica, in: world.storage)
    #expect(Array(stored.bases.keys) == [second] && stored.segments.isEmpty)
    try await writer.expectOwnDeletes()
  }

  @Test("should never count or delete a segment younger than the age, even when forced")
  func shouldKeepYoungSegments() async throws {
    let world = SyncCompactWorld()
    var writer = try await SyncWriter.make(world, settings(files: 1))
    for batch in 0..<3 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 14)
    #expect(try await writer.harness.engine.compact() == .notNeeded)
    try await writer.restart(settings())

    let outcome = try await writer.harness.engine.compact(force: true)

    guard case .compacted(let base, 0, 0) = outcome else { throw SyncFixtureFailure("expected a base and no deletion, got \(outcome)") }
    let stored = try await SyncStoredFiles.read(writer.replica, in: world.storage)
    #expect(stored.segments.count == 3)
    #expect(stored.bases[base]?.isComplete == true)
    #expect(writer.provider.deleted.isEmpty)
  }
}

@Suite("SyncEngine compaction path")
struct SyncCompactPathTests {
  @Test("should leave a complete base, delete covered old segments, keep recent ones and converge an old and a fresh reader")
  func shouldCompactAndConverge() async throws {
    let world = SyncCompactWorld()
    let writer = try await SyncWriter.make(world, settings(files: 2, partBytes: 1_500))
    let readerProvider = SyncCompactProvider(wrapping: world.storage)
    let reader = try await world.started(world.harness("reader", store: try world.openStore(), provider: readerProvider, configuration: settings()))
    for batch in 0..<3 { _ = try await writer.upload(3, prefix: "old\(batch)-") }
    _ = try await reader.engine.sync()
    world.advance(days: 20)
    let recent = try await writer.upload(2, prefix: "new")

    let outcome = try await writer.harness.engine.compact()

    guard case .compacted(let base, let deletedSegments, 0) = outcome else { throw SyncFixtureFailure("expected a base, got \(outcome)") }
    let stored = try await SyncStoredFiles.read(writer.replica, in: world.storage)
    #expect(stored.bases.count == 1 && stored.bases[base]?.isComplete == true && (stored.bases[base]?.parts ?? 0) > 1)
    #expect(stored.segments == Set(recent))
    let entries = try await SyncCompactCheck.entries(writer.harness)
    #expect(Set(entries.filter { !$0.isBase && $0.isLive }.map(\.point)) == stored.segments)
    #expect(entries.filter { !$0.isBase && !$0.isLive }.count == deletedSegments && deletedSegments == 3)
    #expect(entries.filter { $0.isBase }.map(\.point) == [base] && entries.first { $0.isBase }?.parts == stored.bases[base]?.parts)
    #expect(try await SyncCompactCheck.row(writer.harness) == nil)
    let manifestData = try await world.storage.get(VaultPath.manifest(writer.replica))
    let manifest = try ReplicaManifestCodec.open(manifestData, at: VaultPath.manifest(writer.replica), vault: SyncFixture.vault) { writer.harness.ring.key($0) }
    #expect(manifest.base.map { StreamPoint(last: $0.upTo, tag: $0.tag) } == base)
    try await writer.expectOwnDeletes()

    let fresh = try await world.started(world.harness("fresh", store: try world.openStore(), configuration: settings()))
    for _ in 0..<4 {
      for peer in [writer.harness, reader, fresh] { _ = try await peer.engine.sync() }
    }
    let digests = try await [writer.harness.digest(), reader.digest(), fresh.digest()]
    #expect(Set(digests).count == 1)
    #expect(try await fresh.appliedFiles()[writer.replica]?.bases == [base])
    let parts = try #require(stored.bases[base]?.parts)
    let partKeys = (1...parts).map { VaultPath.basePart(writer.replica, upTo: base.last, tag: base.tag, part: $0, parts: parts) }
    #expect(partKeys.allSatisfy { readerProvider.gets(of: $0) == 1 })
  }

  @Test("should postpone and announce nothing when a local write lands between the upload and the snapshot")
  func shouldKeepUnsentChangesOutOfBase() async throws {
    let world = SyncCompactWorld()
    let store = try world.openStore()
    let provider = SyncCompactProvider(wrapping: world.storage)
    let seam = SyncCompactionProbe {
      _ = try await store.write { transaction in try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("late")), ["title": .string("unsent")]) }
    }
    let harness = try await world.started(world.harness("writer", store: store, provider: provider, configuration: settings(), probe: seam), createsKey: true)
    try await harness.writeNotes(3)

    #expect(try await harness.engine.compact(force: true) == .postponed)

    #expect(try await SyncCompactCheck.entries(harness).allSatisfy { !$0.isBase })
    #expect(try await SyncCompactCheck.row(harness) == nil)
    #expect(basePuts(provider).isEmpty)
    #expect(try await harness.pendingLines().count == 1)
  }

  @Test("should delete nothing while the listing does not show the new base, and clean up on the next call")
  func shouldWaitForListedBase() async throws {
    let world = SyncCompactWorld()
    let writer = try await SyncWriter.make(world, settings(files: 1))
    for batch in 0..<3 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 20)
    writer.provider.hide(VaultPath.basePrefix(writer.replica))

    guard case .compacted(let base, 0, 0) = try await writer.harness.engine.compact() else { throw SyncFixtureFailure("expected a base and no deletion") }
    #expect(writer.provider.deleted.isEmpty)
    writer.provider.reveal()

    #expect(try await writer.harness.engine.compact() == .cleaned(deletedSegments: 3, deletedBases: 0))
    let stored = try await SyncStoredFiles.read(writer.replica, in: world.storage)
    #expect(Array(stored.bases.keys) == [base] && stored.segments.isEmpty)
    try await writer.expectOwnDeletes()
  }

  @Test("should never delete another writer's files under its prefix: it re-mints first")
  func shouldDeleteOnlyItsOwnNames() async throws {
    let world = SyncCompactWorld()
    let writer = try await SyncWriter.make(world, settings(files: 1))
    for batch in 0..<3 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 20)
    guard case .compacted = try await writer.harness.engine.compact() else { throw SyncFixtureFailure("expected a first base") }
    for batch in 3..<5 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 40)
    let old = writer.replica
    let key = try #require(writer.harness.ring.writingKey())
    let head = try #require(try await SyncCompactCheck.entries(writer.harness).filter { !$0.isBase }.map(\.point).max())
    let otherLine = try #require(try await writer.harness.store.ownSnapshot().lines.first)
    let segment = try await SyncPlant.segment([otherLine], replica: old, first: head.last + 1, previous: head, key: key, in: world.storage)
    guard let header = BaseHeader(replica: old, upTo: head.last, through: head, schema: 3), let file = BaseFile(header: header, lines: [otherLine]) else {
      throw SyncFixtureFailure("the planted base is invalid")
    }
    let base = try BaseCodec.seal(file, vault: SyncFixture.vault, with: key)
    try await SyncPlant.put(base, in: world.storage)
    let planted = [segment.key] + base.map(\.key)

    #expect(try await writer.harness.engine.compact(force: true) == .postponed)
    #expect(writer.store.replica != old)
    _ = try await writer.harness.engine.upload()
    _ = try await writer.harness.engine.compact(force: true)
    world.advance(days: 40)
    _ = try await writer.harness.engine.compact(force: true)

    let remaining = Set(try await world.storage.listAll(prefix: VaultPath.replicaPrefix(old)).map(\.key))
    #expect(planted.allSatisfy(remaining.contains))
    #expect(!writer.provider.deleted.contains { planted.contains($0) })
    try await writer.expectOwnDeletes()
  }
}

@Suite("SyncEngine compaction of changed content at the same sequence")
struct SyncCompactSameSequenceTests {
  @Test("should write a new base when the own writes change without a new change, make it current, and remove the older one once the new one is listed")
  func shouldReplaceBaseAtSameSequence() async throws {
    let world = SyncCompactWorld()
    let writer = try await SyncWriter.make(world, settings(age: 0, interval: 0))
    let readerProvider = SyncCompactProvider(wrapping: world.storage)
    let reader = try await world.started(world.harness("reader", store: try world.openStore(), provider: readerProvider, configuration: settings()))
    _ = try await writer.upload(3, prefix: "a")
    guard case .compacted(var current, _, 0) = try await writer.harness.engine.compact(force: true) else { throw SyncFixtureFailure("expected a first base") }
    var bases = [current]
    try await SyncCompactCheck.drain(reader)

    for round in 0..<6 {
      _ = try await writer.store.adoptRemote(try await foreignLines(2, prefix: "adopted\(round)-"))
      writer.provider.hide(VaultPath.basePrefix(writer.replica))
      guard case .compacted(let next, _, 0) = try await writer.harness.engine.compact(force: true) else { throw SyncFixtureFailure("expected a new base in round \(round)") }
      #expect(next.last == current.last && next != current, "round \(round)")
      let replica = writer.replica
      let recorded = try await writer.store.read { try ReplicaHistory.currentBase(of: replica, in: $0.database) }
      #expect(recorded.map { StreamPoint(last: $0.upTo, tag: $0.tag) } == next, "round \(round)")
      #expect(Set(try await SyncStoredFiles.read(replica, in: world.storage).bases.keys) == [current, next], "round \(round)")
      writer.provider.reveal()
      #expect(try await writer.harness.engine.compact() == .cleaned(deletedSegments: 0, deletedBases: 1), "round \(round)")
      #expect(Array(try await SyncStoredFiles.read(replica, in: world.storage).bases.keys) == [next], "round \(round)")
      try await SyncCompactCheck.drain(reader)
      current = next
      bases.append(next)
    }

    for _ in 0..<3 {
      _ = try await writer.harness.engine.sync()
      _ = try await reader.engine.sync()
    }
    #expect(try await reader.digest() == (try await writer.harness.digest()))
    let partKeys = bases.flatMap { base in [VaultPath.basePart(writer.replica, upTo: base.last, tag: base.tag, part: 1, parts: 1)] }
    #expect(partKeys.allSatisfy { readerProvider.gets(of: $0) == 1 })
    try await writer.expectOwnDeletes()
  }
}

@Suite("SyncEngine compaction of a shared prefix")
struct SyncCompactSharedPrefixTests {
  @Test("should never delete a second writer's segment with the same sequence numbers as a recorded one, whenever the listing shows it", arguments: [0, 1, 2])
  func shouldIgnoreForeignSegmentWithRecordedSequences(listings: Int) async throws {
    let world = SyncCompactWorld()
    let writer = try await SyncWriter.make(world, settings(files: 1))
    for batch in 0..<3 { _ = try await writer.upload(2, prefix: "b\(batch)-") }
    world.advance(days: 20)
    let replica = writer.replica
    let key = try #require(writer.harness.ring.writingKey())
    let recorded = try #require(try await SyncCompactCheck.entries(writer.harness).first { !$0.isBase })
    let first = try #require(recorded.first)
    let lines = try await foreignLines(Int(recorded.point.last - first + 1), prefix: "other")
    let other = try await SyncPlant.segment(lines, replica: replica, first: first, key: key, in: world.storage)
    #expect(VaultPath.classify(other.key) == .segment(replica, first: first, last: recorded.point.last, tag: other.tag) && other.tag != recorded.point.tag)
    writer.provider.delay(other.key, listings: listings)

    _ = try await writer.harness.engine.compact()
    _ = try await writer.harness.engine.compact()

    #expect(try await world.storage.listAll(prefix: VaultPath.replicaPrefix(replica)).contains { $0.key == other.key })
    #expect(!writer.provider.deleted.contains(other.key))
    #expect(writer.store.replica != replica)
    try await writer.expectOwnDeletes()
  }
}

@Suite("SyncEngine compaction parts")
struct SyncCompactPartTests {
  @Test("should split a base larger than the part budget into parts that each fit the provider's object limit")
  func shouldSplitIntoFittingParts() async throws {
    let world = SyncCompactWorld()
    var writer = try await SyncWriter.make(world, settings())
    for batch in 0..<4 {
      try await writer.harness.writeNotes(8, prefix: "b\(batch)-") { _ in (0..<4).map { _ in UUID().uuidString }.joined() }
      _ = try await writer.harness.uploaded()
    }
    let limit = 1_200
    let limited = SyncCompactProvider(wrapping: world.storage, maxObjectBytes: limit)
    writer.harness = world.harness("writer", store: writer.store, provider: limited, configuration: settings())
    _ = try await writer.harness.engine.start()

    guard case .compacted(let base, _, _) = try await writer.harness.engine.compact(force: true) else { throw SyncFixtureFailure("expected a base") }

    let stored = try await SyncStoredFiles.read(writer.replica, in: world.storage)
    #expect(stored.bases[base]?.isComplete == true)
    #expect((stored.bases[base]?.parts ?? 0) > 2)
    #expect(stored.partSizes.allSatisfy { $0 <= limit })
    let reader = try await world.started(world.harness("reader", store: try world.openStore(), configuration: settings()))
    try await SyncCompactCheck.drain(reader)
    #expect(try await reader.appliedFiles()[writer.replica]?.bases == [base])
  }

  @Test("should refuse a base whose parts cannot fit the provider before announcing or putting anything")
  func shouldRefuseUnfittableBase() async throws {
    let world = SyncCompactWorld()
    var writer = try await SyncWriter.make(world, settings())
    _ = try await writer.upload(3, prefix: "b")
    let limited = SyncCompactProvider(wrapping: world.storage, maxObjectBytes: 120)
    writer.harness = world.harness("writer", store: writer.store, provider: limited, configuration: settings())
    _ = try await writer.harness.engine.start()

    let error = await #expect(throws: SyncError.self) { try await writer.harness.engine.compact(force: true) }

    guard case .baseTooLarge? = error else { throw SyncFixtureFailure("expected the base to be refused, got \(String(describing: error))") }
    #expect(basePuts(limited).isEmpty)
    #expect(try await SyncCompactCheck.entries(writer.harness).allSatisfy { !$0.isBase })
    #expect(try await SyncCompactCheck.row(writer.harness) == nil)
  }

  @Test("should refuse a base holding a record the provider's class policy does not admit")
  func shouldRefuseUnadmittedClass() async throws {
    let world = SyncCompactWorld()
    var writer = try await SyncWriter.make(world, settings())
    _ = try await writer.harness.store.write { transaction in
      try transaction.set(EntityRef(kind: SyncFixture.vital, key: ReplicaFixture.key("pulse")), ["value": .int(60)])
    }
    _ = try await writer.harness.uploaded()
    let policy = SyncPolicyProvider(wrapping: world.storage, classPolicy: .iCloud)
    writer.harness = world.harness("writer", store: writer.store, provider: policy, configuration: settings())
    _ = try await writer.harness.engine.start()

    let error = await #expect(throws: SyncError.self) { try await writer.harness.engine.compact(force: true) }

    guard case .syncClassRefused(SyncFixture.vital, .health)? = error else { throw SyncFixtureFailure("expected the class refusal, got \(String(describing: error))") }
    #expect(try await SyncCompactCheck.entries(writer.harness).allSatisfy { !$0.isBase })
  }
}

/// Shared storage seen through another class policy, as a second provider over the same objects.
final class SyncPolicyProvider: StorageProvider {
  private let inner: any StorageProvider
  private let classPolicy: StorageClassPolicy

  init(wrapping inner: any StorageProvider, classPolicy: StorageClassPolicy) {
    self.inner = inner
    self.classPolicy = classPolicy
  }

  var capabilities: StorageCapabilities {
    let base = inner.capabilities
    return StorageCapabilities(
      pushesChangeNotices: base.pushesChangeNotices, supportsPutIfAbsent: base.supportsPutIfAbsent, hasChangeFeed: base.hasChangeFeed,
      reportsServerTime: base.reportsServerTime, maxObjectBytes: base.maxObjectBytes, classPolicy: classPolicy)
  }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}
