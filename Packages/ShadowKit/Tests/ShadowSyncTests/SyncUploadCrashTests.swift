import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private func crash(_ harness: SyncHarness) async {
  let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
  guard case .corruptState("injected crash")? = error else {
    Issue.record("expected the injected crash, got \(String(describing: error))")
    return
  }
}

private func expectedRecovery(after step: SyncUploadStep) -> Bool {
  switch step {
  case .outboxSaved, .putDone: true
  case .recorded, .dropped: false
  }
}

private func restarted(
  _ store: VaultStore, _ provider: any StorageProvider, _ keychain: InMemoryKeychain, _ configuration: SyncConfiguration, crashAt step: SyncUploadStep?
) async throws -> SyncHarness {
  let harness = SyncHarness(store: store, provider: provider, keychain: keychain, configuration: configuration, crashAt: step)
  _ = try await harness.engine.start()
  return harness
}

private func runHostileRounds(_ generator: inout SeededGenerator, reportsServerTime: Bool) async throws {
  let startClock: @Sendable () -> Date = { SyncFixture.start }
  let serverClock = reportsServerTime ? startClock : nil
  let inner = InMemoryStorageProvider(pageSize: generator.int(in: 1...4), serverClock: serverClock)
  let plan = FaultPlan(transientFailure: 0.2, lostAcknowledgement: 0.25, staleListing: 0.5, partialPage: 0.5)
  let provider = FaultInjectingStorageProvider(wrapping: inner, seed: generator.next(), plan: plan)
  let keychain = InMemoryKeychain()
  let store = try SyncFixture.open()
  let configuration = SyncConfiguration(maximumSegmentLines: generator.int(in: 1...4))
  var harness = try await SyncHarness.started(store: store, provider: provider, keychain: keychain, configuration: configuration)
  let replica = store.replica
  var written = 0
  for batch in 0..<generator.int(in: 1...4) {
    let size = generator.int(in: 1...6)
    try await harness.writeNotes(size, prefix: "b\(batch)-")
    written += size
    var attempts = 0
    while true {
      attempts += 1
      guard attempts <= 200 else { throw SyncFixtureFailure("upload never succeeded") }
      let crashing = generator.chance(0.25)
      if crashing { harness = try await restarted(store, provider, keychain, configuration, crashAt: generator.pick(from: SyncUploadStep.allCases)) }
      do {
        _ = try await harness.engine.upload()
        break
      } catch {
        let firstPending = try await store.pendingChanges(limit: 1).first?.sequence ?? Int64.max
        let recorded = try await harness.history().segments.map { $0.last }.max() ?? 0
        guard firstPending == Int64.max || recorded >= firstPending - 1 else { throw SyncFixtureFailure("a change was dropped before it was recorded") }
        if crashing || generator.chance(0.5) { harness = try await restarted(store, provider, keychain, configuration, crashAt: nil) }
      }
    }
    provider.setFaultsEnabled(false)
    let segments = try await SyncStoredSegment.all(in: inner, prefix: VaultPath.segmentPrefix(replica), ring: harness.ring)
    provider.setFaultsEnabled(true)
    try SyncChain.verify(segments, count: segments.last?.file.header.last ?? 0, history: try await harness.history())
    guard store.replica == replica else { throw SyncFixtureFailure("the replica was re-minted") }
  }
  provider.setFaultsEnabled(false)
  provider.heal()
  #expect(try await harness.pendingLines().isEmpty)
  let segments = try await SyncStoredSegment.all(in: inner, prefix: VaultPath.replicasPrefix, ring: harness.ring)
  let count = segments.last?.file.header.last ?? 0
  #expect(count > Int64(written))
  try SyncChain.verify(segments, count: count, history: try await harness.history())
}

@Suite("SyncEngine upload crash safety")
struct SyncUploadCrashTests {
  @Test("should store every change exactly once after a crash at each durable step", arguments: SyncUploadStep.allCases)
  func shouldRecoverFromCrash(at step: SyncUploadStep) async throws {
    let directory = ReplicaTemporaryDirectory()
    let location = StoreLocation.file(directory.database("vault"))
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let configuration = SyncConfiguration(maximumSegmentLines: 2)
    let crashing = try await SyncHarness.started(
      store: try SyncFixture.open(location), provider: provider, keychain: keychain, configuration: configuration, crashAt: step)
    try await crashing.writeNotes(5)
    let count = Int64(try await crashing.pendingLines().count)

    await crash(crashing)

    let firstPending = try await crashing.store.pendingChanges(limit: 1).first?.sequence ?? count + 1
    let recorded = try await crashing.history().segments.map(\.last).max() ?? 0
    #expect(recorded >= firstPending - 1, "a change was dropped before the history recorded the file holding it")

    let fresh = SyncHarness(store: try SyncFixture.open(location), provider: provider, keychain: keychain, configuration: configuration)
    #expect(try await fresh.engine.start() == .alreadyRunning)
    let outcome = try await fresh.engine.upload()

    guard case .uploaded(let points) = outcome else { throw SyncFixtureFailure("the recovery uploaded nothing") }
    let segments = try await fresh.segments()
    #expect(points.count == segments.count - (expectedRecovery(after: step) ? 0 : 1))
    #expect(try await fresh.pendingLines().isEmpty)
    #expect(try await fresh.savedUpload() == nil)
    try SyncChain.verify(segments, count: count, history: try await fresh.history())
  }

  @Test("should re-send the saved bytes under the saved name after more remote changes were applied")
  func shouldResendSavedBytes() async throws {
    let directory = ReplicaTemporaryDirectory()
    let location = StoreLocation.file(directory.database("vault"))
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let crashing = try await SyncHarness.started(store: try SyncFixture.open(location), provider: provider, keychain: keychain, crashAt: .outboxSaved)
    try await crashing.writeNotes(3)
    await crash(crashing)
    let saved = try #require(try await crashing.savedUpload())
    #expect(provider.callCounts.put == 0)

    let fresh = SyncHarness(store: try SyncFixture.open(location), provider: provider, keychain: keychain)
    try await fresh.recordApplied(ReplicaFixture.point(4, 9), of: ReplicaFixture.replica("0193a0f0-0000-7000-8000-000000000001"))
    _ = try await fresh.engine.start()
    let outcome = try await fresh.engine.upload()

    #expect(outcome == .uploaded([saved.point]))
    #expect(try await provider.get(saved.key) == saved.data)
    let segments = try await fresh.segments()
    #expect(segments.map(\.key) == [saved.key])
    #expect(segments.first?.file.header.dependencies.isEmpty == true)
  }

  @Test("should drop a saved upload of a re-minted id and send its changes under the new id")
  func shouldDropSavedUploadOfOldReplica() async throws {
    let directory = ReplicaTemporaryDirectory()
    let location = StoreLocation.file(directory.database("vault"))
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let crashing = try await SyncHarness.started(store: try SyncFixture.open(location), provider: provider, keychain: keychain, crashAt: .outboxSaved)
    try await crashing.writeNotes(3)
    let pending = try await crashing.pendingLines()
    await crash(crashing)
    let old = crashing.store.replica
    try keychain.device("phone").store(service: "marker", scope: .device).removeValue(forKey: DeviceMarker.itemName(vault: SyncFixture.vault))

    let fresh = SyncHarness(store: try SyncFixture.open(location), provider: provider, keychain: keychain)
    #expect(try await fresh.engine.start() == .reminted(from: old, reason: .markerMissing))
    guard case .uploaded = try await fresh.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    #expect(try await provider.listAll(prefix: VaultPath.replicaPrefix(old)).isEmpty)
    let segments = try await fresh.segments(of: fresh.store.replica)
    #expect(Array(segments.flatMap(\.file.lines).prefix(pending.count)) == pending)
    #expect(try await fresh.savedUpload() == nil)
    #expect(try await fresh.pendingLines().isEmpty)
  }

  @Test("should treat an existing file under the saved name as a finished put")
  func shouldAcceptExistingFile() async throws {
    let directory = ReplicaTemporaryDirectory()
    let location = StoreLocation.file(directory.database("vault"))
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let crashing = try await SyncHarness.started(store: try SyncFixture.open(location), provider: provider, keychain: keychain, crashAt: .putDone)
    try await crashing.writeNotes(3)
    await crash(crashing)
    let saved = try #require(try await crashing.savedUpload())

    let fresh = SyncHarness(store: try SyncFixture.open(location), provider: provider, keychain: keychain)
    _ = try await fresh.engine.start()

    #expect(try await fresh.engine.upload() == .uploaded([saved.point]))
    #expect(provider.callCounts.put == 2)
    #expect(try await fresh.history().segments == [saved.point])
  }

  @Test("should keep every change once in a valid chain under a hostile provider and random crashes", arguments: [false, true])
  func shouldSurviveHostileProvider(reportsServerTime: Bool) async throws {
    try await forAll(iterations: 25, seed: reportsServerTime ? 0xC0FFEF : 0xC0FFEE) { generator in
      try await runHostileRounds(&generator, reportsServerTime: reportsServerTime)
    }
  }
}
