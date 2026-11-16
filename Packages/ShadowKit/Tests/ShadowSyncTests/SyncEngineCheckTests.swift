import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private let yearAhead = SyncFixture.start.addingTimeInterval(365 * 86_400)

private func objects(_ provider: InMemoryStorageProvider, under prefix: String) async throws -> [ObjectKey: Data] {
  var result: [ObjectKey: Data] = [:]
  for object in try await provider.listAll(prefix: prefix) { result[object.key] = try await provider.get(object.key) }
  return result
}

private func garbleMarker(_ keychain: InMemoryKeychain) throws {
  try keychain.device("phone").store(service: "marker", scope: .device).setData(Data("garbage".utf8), forKey: DeviceMarker.itemName(vault: SyncFixture.vault))
}

private func floor(at date: Date) -> HLCTimestamp? {
  HLCTimestamp(wallMillis: Int64(date.timeIntervalSince1970 * 1_000), counter: 0, replica: ReplicaFixture.replica("0193a0f0-0000-7000-8000-0000000000ff"))
}

private struct ClockedHarness {
  let harness: SyncHarness

  init(provider: InMemoryStorageProvider, device: Date, publicFloor: HLCTimestamp? = nil) throws {
    let trusted = TrustedClock(wallClock: { device }, monotonic: SyncFixedMonotonic())
    let store = try SyncFixture.open(wallClock: SyncEngine.wallClock(preferring: trusted) { device })
    harness = SyncHarness(store: store, provider: provider, trustedClock: trusted, wallClock: { device }, publicFloor: { publicFloor })
  }

  func started() async throws -> SyncHarness {
    _ = try harness.ring.createKey()
    _ = try await harness.engine.start()
    return harness
  }
}

@Suite("SyncEngine self-check")
struct SyncEngineSelfCheckTests {
  @Test("should re-mint and upload under a new prefix, leaving the old prefix untouched, when a foreign segment sits under its own prefix", arguments: [false, true])
  func shouldRemintOnForeignSegment(reportsServerTime: Bool) async throws {
    let startClock: @Sendable () -> Date = { SyncFixture.start }
    let provider = InMemoryStorageProvider(serverClock: reportsServerTime ? startClock : nil)
    let harness = try await SyncHarness.started(provider: provider)
    _ = try await harness.engine.upload()
    let old = harness.store.replica
    try await harness.writeNotes(3)
    let pending = try await harness.pendingLines()
    let foreign = VaultPath.segment(old, first: 1, last: 1, tag: ReplicaFixture.tag(42))
    _ = try await provider.put(foreign, data: Data("someone else".utf8), condition: .ifAbsent)
    let before = try await objects(provider, under: VaultPath.replicaPrefix(old))

    guard case .uploaded(let points) = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    let replica = harness.store.replica
    #expect(replica != old)
    #expect(try await objects(provider, under: VaultPath.replicaPrefix(old)) == before)
    let segments = try await harness.segments(of: replica)
    #expect(segments.map(\.point) == points && segments.first?.file.header.first == 1)
    let uploaded = segments.flatMap(\.file.lines)
    #expect(Array(uploaded.prefix(pending.count)) == pending)
    #expect(try await harness.pendingLines().isEmpty)
    #expect(try await harness.lifecycle.directory().isRetired(old))
  }

  @Test("should finish an interrupted re-mint on the next upload and then upload under the new id")
  func shouldResumeInterruptedRemint() async throws {
    let provider = InMemoryStorageProvider()
    let harness = try await SyncHarness.started(provider: provider, lifecycleCrashAt: .remintMoved)
    let old = harness.store.replica
    _ = try await provider.put(VaultPath.segment(old, first: 1, last: 1, tag: ReplicaFixture.tag(42)), data: Data("someone else".utf8), condition: .ifAbsent)
    try await harness.writeNotes(2)
    let pending = try await harness.pendingLines()

    let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
    guard case .lifecycle(.corruptState("injected crash"))? = error else { throw SyncFixtureFailure("expected the injected crash, got \(String(describing: error))") }
    #expect(provider.callCounts.put == 1)

    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    let replica = harness.store.replica
    #expect(replica != old)
    #expect(try await harness.lifecycle.directory().isRetired(old))
    #expect(Array(try await harness.segments(of: replica).flatMap(\.file.lines).prefix(pending.count)) == pending)
  }

  @Test("should not re-mint when the listing still shows a file the history marks deleted")
  func shouldIgnoreDeletedFile() async throws {
    let provider = InMemoryStorageProvider()
    let harness = try await SyncHarness.started(provider: provider)
    let replica = harness.store.replica
    guard case .uploaded(let first) = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }
    let deleted = try #require(first.last)
    try await harness.store.write { transaction in
      try ReplicaHistory.markDeleted(deleted, isBase: false, replica: replica, at: 1, in: transaction.database)
    }
    try await harness.writeNotes(2)

    guard case .uploaded(let second) = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    #expect(harness.store.replica == replica)
    #expect(try await harness.segments().map(\.point) == first + second)
  }

  @Test("should not re-mint when the listing omits a recent own file")
  func shouldToleratePartialListing() async throws {
    let provider = InMemoryStorageProvider()
    let harness = try await SyncHarness.started(provider: provider)
    let replica = harness.store.replica
    guard case .uploaded(let first) = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }
    try await provider.delete(first.map { VaultPath.segment(replica, first: 1, last: $0.last, tag: $0.tag) })
    try await harness.writeNotes(2)

    guard case .uploaded(let second) = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    #expect(harness.store.replica == replica)
    #expect(try await harness.segments().first?.file.header.previous == first.last)
    #expect(second.count == 1)
  }

  @Test("should postpone without an error when the marker becomes unreadable between the self-check and the re-mint")
  func shouldPostponeWhenMarkerFailsBeforeRemint() async throws {
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let marker = SyncFlakySecureStore(wrapping: keychain.device("phone").store(service: "marker", scope: .device))
    let harness = SyncHarness(store: try SyncFixture.open(), provider: provider, keychain: keychain, markerStore: marker)
    _ = try harness.ring.createKey()
    _ = try await harness.engine.start()
    let old = harness.store.replica
    _ = try await provider.put(VaultPath.segment(old, first: 1, last: 1, tag: ReplicaFixture.tag(42)), data: Data("someone else".utf8), condition: .ifAbsent)
    try await harness.writeNotes(2)
    let pending = try await harness.pendingLines()
    marker.failReads(after: 1)

    #expect(try await harness.engine.upload() == .postponed)
    #expect(try await harness.engine.upload() == .postponed)
    #expect(harness.store.replica == old && provider.callCounts.put == 1)
    #expect(try await harness.pendingLines() == pending)

    marker.heal()
    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }
    #expect(harness.store.replica != old)
  }

  @Test("should postpone and put nothing while the device marker cannot be read")
  func shouldPostponeOnUnreadableMarker() async throws {
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let harness = try await SyncHarness.started(provider: provider, keychain: keychain)
    try garbleMarker(keychain)
    let pending = try await harness.pendingLines()

    #expect(try await harness.engine.upload() == .postponed)

    #expect(provider.callCounts.put == 0)
    #expect(try await harness.pendingLines() == pending)
  }
}

@Suite("SyncEngine writing key")
struct SyncEngineKeyTests {
  @Test("should wait for a key and then upload the same changes")
  func shouldAwaitKey() async throws {
    let provider = InMemoryStorageProvider()
    let harness = try await SyncHarness.started(provider: provider, withKey: false)
    try await harness.writeNotes(2)
    let pending = try await harness.pendingLines()

    #expect(try await harness.engine.upload() == .awaitingKey(floor: nil))
    #expect(provider.callCounts.put == 0)

    _ = try harness.ring.createKey()
    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }
    #expect(try await harness.segments().flatMap(\.file.lines) == pending)
  }

  @Test("should name the unmet rotation floor when every key it holds is below it")
  func shouldReportUnmetFloor() async throws {
    let provider = InMemoryStorageProvider()
    let harness = try await SyncHarness.started(provider: provider, withKey: false)
    try harness.ring.add(VaultKey.generate(id: SyncFixture.keyID(1)))
    try await harness.raiseDirectoryFloors(key: SyncFixture.keyID(5))

    #expect(try await harness.engine.upload() == .awaitingKey(floor: SyncFixture.keyID(5)))
    #expect(provider.callCounts.put == 0)
  }

  @Test("should seal with the oldest key at or above the rotation floor")
  func shouldUseKeyAboveFloor() async throws {
    let harness = try await SyncHarness.started(withKey: false)
    let older = VaultKey.generate(id: SyncFixture.keyID(1))
    let newer = VaultKey.generate(id: SyncFixture.keyID(2))
    try harness.ring.add(newer)
    try harness.ring.add(older)
    _ = try await harness.engine.upload()
    #expect(try VaultFile.header(of: try #require(try await harness.segments().last).data).keyID == older.id)

    let directory = try await harness.lifecycle.directory()
    try await harness.store.write { transaction in try directory.raiseKeyFloor(to: newer.id, in: &transaction) }
    _ = try await harness.engine.upload()

    #expect(try VaultFile.header(of: try #require(try await harness.segments().last).data).keyID == newer.id)
  }
}

@Suite("SyncEngine floors")
struct SyncEngineFloorTests {
  @Test("should keep sealing with the floor key and keep the minimum schema after a rebuild clears the directory")
  func shouldKeepFloorsAfterRebuild() async throws {
    let directory = ReplicaTemporaryDirectory()
    let location = StoreLocation.file(directory.database("vault"))
    let provider = InMemoryStorageProvider(serverClock: { SyncFixture.start })
    let keychain = InMemoryKeychain()
    let trusted = TrustedClock(wallClock: { SyncFixture.start }, monotonic: SyncFixedMonotonic())
    let before = SyncHarness(
      store: try SyncFixture.open(location, wallClock: SyncEngine.wallClock(preferring: trusted) { SyncFixture.start }), provider: provider, keychain: keychain,
      trustedClock: trusted)
    let newer = VaultKey.generate(id: SyncFixture.keyID(2))
    try before.ring.add(VaultKey.generate(id: SyncFixture.keyID(1)))
    try before.ring.add(newer)
    _ = try await before.engine.start()
    try await before.raiseDirectoryFloors(key: newer.id, schema: 2)
    _ = try await before.engine.upload()
    #expect(try await before.savedFloors() == SyncFloors(key: newer.id, schema: 2))
    let old = before.store.replica

    let restartedClock = TrustedClock(wallClock: { yearAhead }, monotonic: SyncFixedMonotonic())
    let harness = SyncHarness(
      store: try SyncFixture.open(location, wallClock: SyncEngine.wallClock(preferring: restartedClock) { yearAhead }), provider: provider, keychain: keychain,
      trustedClock: restartedClock, wallClock: { yearAhead })
    _ = try await harness.engine.start()
    try await harness.writeNotes(1)
    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    let replica = harness.store.replica
    #expect(replica != old)
    let current = try await harness.lifecycle.directory()
    #expect(current.keyFloor == nil && current.minimumSchema == nil)
    let segments = try await harness.segments(of: replica)
    let segment = try #require(segments.last)
    #expect(try VaultFile.header(of: segment.data).keyID == newer.id)
    let records = try segments.flatMap(\.file.lines).map { try ChangeRecord(json: CanonicalJSON.decode($0)) }
    #expect(records.allSatisfy { abs($0.clock.date.timeIntervalSince(SyncFixture.start)) < 60 })
    #expect(try await harness.engine.minimumSchema() == 2)
    #expect(try await harness.savedFloors() == SyncFloors(key: newer.id, schema: 2))
  }

  @Test("should never lower the saved floors")
  func shouldNeverLowerFloors() async throws {
    let harness = try await SyncHarness.started()
    try await harness.raiseDirectoryFloors(key: SyncFixture.keyID(5), schema: 3)
    #expect(try await harness.engine.minimumSchema() == 3)

    let lowered = try await harness.store.write { transaction in
      try SyncFloorTable.raise(to: SyncFloors(key: SyncFixture.keyID(1), schema: 1), in: transaction.database)
    }
    let cleared = try await harness.store.write { transaction in try SyncFloorTable.raise(to: SyncFloors(), in: transaction.database) }

    #expect(lowered == SyncFloors(key: SyncFixture.keyID(5), schema: 3) && cleared == lowered)
    #expect(try await harness.savedFloors() == lowered)
  }

  @Test("should refuse to upload and keep the pending changes when the vault needs a newer schema")
  func shouldRefuseNewerSchema() async throws {
    let provider = InMemoryStorageProvider()
    let harness = try await SyncHarness.started(provider: provider)
    try await harness.writeNotes(2)
    try await harness.raiseDirectoryFloors(schema: SyncFixture.registry.version + 1)
    let pending = try await harness.pendingLines()

    let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
    guard case .appUpdateRequired(let minimum, let current)? = error else { throw SyncFixtureFailure("expected appUpdateRequired, got \(String(describing: error))") }

    #expect(minimum == SyncFixture.registry.version + 1 && current == SyncFixture.registry.version)
    #expect(provider.callCounts.put == 0)
    #expect(try await harness.pendingLines() == pending)
    #expect(try await harness.engine.minimumSchema() == SyncFixture.registry.version + 1)
  }
}

@Suite("SyncEngine clock check")
struct SyncEngineClockTests {
  @Test("should re-stamp unsent changes from trusted time in a new replica once when the device clock is a year ahead", arguments: [false, true])
  func shouldCorrectWrongClock(floorNearTrustedTime: Bool) async throws {
    let provider = InMemoryStorageProvider(serverClock: { SyncFixture.start })
    let publicFloor = floorNearTrustedTime ? floor(at: SyncFixture.start) : nil
    let harness = try await ClockedHarness(provider: provider, device: yearAhead, publicFloor: publicFloor).started()
    try await harness.writeNotes(3)
    let old = harness.store.replica
    let other = ReplicaFixture.replica("0193a0f0-0000-7000-8000-000000000002")
    try await harness.recordApplied(ReplicaFixture.point(3, 5), of: other)
    #expect(try await harness.engine.appliedPoints() == [other: ReplicaFixture.point(3, 5)])

    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    let replica = harness.store.replica
    #expect(replica != old)
    guard case .wrong(let skew) = await harness.engine.deviceClock else { throw SyncFixtureFailure("the wrong clock was not reported") }
    #expect(skew > .seconds(364 * 86_400))
    #expect(try await harness.engine.appliedPoints().isEmpty)
    let records = try await harness.segments(of: replica).flatMap(\.file.lines).map { try ChangeRecord(json: CanonicalJSON.decode($0)) }
    #expect(records.contains { $0.entity == SyncFixture.note })
    #expect(records.allSatisfy { abs($0.clock.date.timeIntervalSince(SyncFixture.start)) < 60 && $0.clock.replica == replica })
    #expect(try await harness.segments(of: old).isEmpty)

    try await harness.writeNotes(1, prefix: "later")
    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }
    #expect(harness.store.replica == replica)
  }

  @Test("should never re-mint when every wrong stamp sits within tolerance of a polluted public floor")
  func shouldNotRemintAbovePollutedFloor() async throws {
    let provider = InMemoryStorageProvider(serverClock: { SyncFixture.start })
    let harness = try await ClockedHarness(provider: provider, device: yearAhead, publicFloor: floor(at: yearAhead)).started()
    let replica = harness.store.replica

    for round in 0..<3 {
      try await harness.writeNotes(2, prefix: "r\(round)-")
      let pending = try await harness.pendingLines()
      #expect(try ChangeRecord(json: CanonicalJSON.decode(try #require(pending.last))).clock.date >= yearAhead)

      guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("round \(round) uploaded nothing") }

      #expect(harness.store.replica == replica)
      #expect(try await harness.pendingLines().isEmpty)
      guard case .wrong = await harness.engine.deviceClock else { throw SyncFixtureFailure("the wrong clock was not reported") }
    }
    #expect(try await harness.segments(of: replica).count == 3)
  }

  @Test("should not re-mint after the store acknowledged an upload stamped a year ahead")
  func shouldNotRemintAboveAcknowledgedClock() async throws {
    let provider = SyncLateServerTimeProvider(wrapping: InMemoryStorageProvider(), serverTime: SyncFixture.start)
    let trusted = TrustedClock(wallClock: { yearAhead }, monotonic: SyncFixedMonotonic())
    let store = try SyncFixture.open(wallClock: SyncEngine.wallClock(preferring: trusted) { yearAhead })
    let keychain = InMemoryKeychain()
    let device = keychain.device("phone")
    let ring = KeyRing(vault: SyncFixture.vault, store: device.store(service: "keys", scope: .synced))
    _ = try ring.createKey()
    let lifecycle = ReplicaLifecycle(
      store: store, vault: SyncFixture.vault, marker: DeviceMarker(store: device.store(service: "marker", scope: .device)), device: ReplicaFixture.phone,
      wallClock: { yearAhead })
    let engine = SyncEngine(store: store, provider: provider, vault: SyncFixture.vault, ring: ring, lifecycle: lifecycle, trustedClock: trusted, wallClock: { yearAhead })
    _ = try await engine.start()
    let note = EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("n1"))
    try await store.write { transaction in _ = try transaction.set(note, ["title": "ahead"]) }
    guard case .uploaded = try await engine.upload() else { throw SyncFixtureFailure("the first batch was not uploaded") }
    let floor = try #require(try await store.publicClockFloor())
    #expect(floor.date >= yearAhead)
    let replica = store.replica

    provider.startReportingServerTime()
    try await store.write { transaction in _ = try transaction.set(note, ["title": "still ahead"]) }
    guard case .uploaded = try await engine.upload() else { throw SyncFixtureFailure("the second batch was not uploaded") }

    #expect(store.replica == replica)
    guard case .wrong = await engine.deviceClock else { throw SyncFixtureFailure("the wrong clock was not reported") }
    #expect(try await store.pendingChanges(limit: 1).isEmpty)
  }

  @Test("should refuse every upload without re-minting while the store stamps with a wrong device clock")
  func shouldRefuseUntrustedStoreClock() async throws {
    let device = SyncSettableClock(yearAhead)
    let trusted = TrustedClock(wallClock: { device.now }, monotonic: SyncFixedMonotonic())
    let provider = InMemoryStorageProvider(serverClock: { SyncFixture.start })
    let harness = SyncHarness(store: try SyncFixture.open { device.now }, provider: provider, trustedClock: trusted, wallClock: { device.now })
    _ = try harness.ring.createKey()
    _ = try await harness.engine.start()
    let replica = harness.store.replica

    for round in 0..<5 {
      try await harness.writeNotes(1, prefix: "r\(round)-")
      let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
      guard case .storeClockUntrusted(let skew)? = error else { throw SyncFixtureFailure("expected storeClockUntrusted, got \(String(describing: error))") }
      #expect(skew > .seconds(364 * 86_400))
      device.set(device.now.addingTimeInterval(600))
    }

    #expect(harness.store.replica == replica)
    #expect(try await harness.segments().isEmpty)
    #expect(try await harness.pendingLines().count > 5)
  }

  @Test("should rebuild once for changes written before trusted time and then stamp from trusted time without re-minting")
  func shouldSettleWithSharedClock() async throws {
    let device = SyncSettableClock(yearAhead)
    let trusted = TrustedClock(wallClock: { device.now }, monotonic: SyncFixedMonotonic())
    let provider = InMemoryStorageProvider(serverClock: { SyncFixture.start })
    let store = try SyncFixture.open(wallClock: SyncEngine.wallClock(preferring: trusted) { device.now })
    let harness = SyncHarness(store: store, provider: provider, trustedClock: trusted, wallClock: { device.now })
    _ = try harness.ring.createKey()
    _ = try await harness.engine.start()
    var replicas = [store.replica]

    for round in 0..<6 {
      try await harness.writeNotes(1, prefix: "r\(round)-")
      guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("round \(round) uploaded nothing") }
      if replicas.last != store.replica { replicas.append(store.replica) }
      device.set(device.now.addingTimeInterval(600))
    }

    #expect(replicas.count == 2)
    let records = try await harness.segments(of: store.replica).flatMap(\.file.lines).map { try ChangeRecord(json: CanonicalJSON.decode($0)) }
    #expect(records.filter { $0.entity == SyncFixture.note }.count == 6)
    #expect(records.allSatisfy { abs($0.clock.date.timeIntervalSince(SyncFixture.start)) < 60 })
    guard case .wrong = await harness.engine.deviceClock else { throw SyncFixtureFailure("the wrong clock was not reported") }
  }

  @Test("should skip the clock check when the provider reports no server time")
  func shouldSkipWithoutServerTime() async throws {
    let harness = try await ClockedHarness(provider: InMemoryStorageProvider(), device: yearAhead).started()
    try await harness.writeNotes(2)
    let replica = harness.store.replica

    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    #expect(harness.store.replica == replica)
    #expect(await harness.engine.deviceClock == .unchecked)
    let records = try await harness.segments().flatMap(\.file.lines).map { try ChangeRecord(json: CanonicalJSON.decode($0)) }
    #expect(records.allSatisfy { $0.clock.date > SyncFixture.start.addingTimeInterval(300 * 86_400) })
  }

  @Test("should change nothing when the device clock is within tolerance")
  func shouldAcceptClockWithinTolerance() async throws {
    let provider = InMemoryStorageProvider(serverClock: { SyncFixture.start })
    let harness = try await ClockedHarness(provider: provider, device: SyncFixture.start.addingTimeInterval(60)).started()
    try await harness.writeNotes(2)
    let replica = harness.store.replica
    let pending = try await harness.pendingLines()

    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    #expect(harness.store.replica == replica)
    #expect(await harness.engine.deviceClock == .correct)
    #expect(try await harness.segments().flatMap(\.file.lines) == pending)
  }
}

@Suite("SyncEngine manifest")
struct SyncEngineManifestTests {
  @Test("should put a decodable manifest after the self-check when the provider reports server time")
  func shouldWriteManifestFirst() async throws {
    let inner = InMemoryStorageProvider(serverClock: { SyncFixture.start })
    let provider = SyncRecordingProvider(wrapping: inner)
    let harness = try await SyncHarness.started(provider: provider)
    let replica = harness.store.replica
    let manifestKey = VaultPath.manifest(replica)

    guard case .uploaded(let points) = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    let operations = provider.operations
    let put = try #require(operations.firstIndex(of: "put \(manifestKey)"))
    let listed = try #require(operations.firstIndex(of: "list \(VaultPath.replicaPrefix(replica))"))
    #expect(listed < put)
    let first = try ReplicaManifestCodec.open(try await inner.get(manifestKey), at: manifestKey, vault: SyncFixture.vault) { harness.ring.key($0) }
    #expect(first.replica == replica && first.head == nil && first.deviceName == ReplicaFixture.phone.name)

    #expect(try await harness.engine.upload() == .nothingToUpload)

    let second = try ReplicaManifestCodec.open(try await inner.get(manifestKey), at: manifestKey, vault: SyncFixture.vault) { harness.ring.key($0) }
    #expect(second.head == points.last)
  }

  @Test("should not put a manifest when the provider reports no server time")
  func shouldSkipManifestWithoutServerTime() async throws {
    let provider = InMemoryStorageProvider()
    let harness = try await SyncHarness.started(provider: provider)
    _ = try await harness.engine.upload()
    #expect(try await provider.listAll(prefix: VaultPath.manifest(harness.store.replica).rawValue).isEmpty)
  }
}
