import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private let crashSettings = SyncConfiguration(
  maximumSegmentLines: 2, compactionAge: SyncDays.duration(15), compactionBytes: .max, compactionFiles: 1, compactionInterval: .zero, basePartBytes: 1_000)

/// A writer with an older base, old segments it covers and recent ones it must keep, about to compact again.
private struct SyncCrashScenario {
  let world: SyncCompactWorld
  let directory: ReplicaTemporaryDirectory
  let location: StoreLocation
  let provider: SyncCompactProvider
  let writer: SyncHarness
  let replica: ReplicaID
  let olderBase: StreamPoint
  let recent: Set<StreamPoint>
  var lines: Set<Data>

  static func make() async throws -> SyncCrashScenario {
    let world = SyncCompactWorld()
    let directory = ReplicaTemporaryDirectory()
    let location = StoreLocation.file(directory.database("writer"))
    let provider = SyncCompactProvider(wrapping: world.storage)
    let writer = try await world.started(world.harness("writer", store: try world.openStore(location), provider: provider, configuration: crashSettings), createsKey: true)
    var lines: Set<Data> = []
    func send(_ count: Int, _ prefix: String) async throws -> [StreamPoint] {
      try await writer.writeNotes(count, prefix: prefix) { "\(prefix) title \($0) \(String(repeating: "~", count: 40))" }
      lines.formUnion(try await writer.pendingLines())
      return try await writer.uploaded()
    }
    _ = try await send(6, "a")
    guard case .compacted(let olderBase, 0, 0) = try await writer.engine.compact(force: true) else { throw SyncFixtureFailure("expected the older base") }
    world.advance(days: 1)
    _ = try await send(6, "m")
    world.advance(days: 19)
    let recent = try await send(3, "y")
    return SyncCrashScenario(
      world: world, directory: directory, location: location, provider: provider, writer: writer, replica: writer.store.replica, olderBase: olderBase, recent: Set(recent),
      lines: lines)
  }

  func engine(probe: SyncCompactionProbe = SyncCompactionProbe(), configuration: SyncConfiguration = crashSettings) async throws -> SyncHarness {
    let harness = world.harness("writer", store: try world.openStore(location), provider: provider, configuration: configuration, probe: probe)
    #expect(try await harness.engine.start() == .alreadyRunning)
    return harness
  }

  /// A reader that has never synced, listing storage with no lag, must reach the merge of everything the writer uploaded.
  func expectFreshReaderConverges(_ name: String) async throws {
    let reader = try await world.started(world.harness(name, store: try world.openStore(), provider: world.storage, configuration: crashSettings))
    try await SyncCompactCheck.drain(reader)
    let expected = try SyncCompactCheck.reference(lines.union(try await reader.pendingLines()))
    #expect(try await reader.digest() == expected, "reader \(name)")
  }

  /// Exactly one complete base, recorded as the only live base, no older base, and every segment the base does not cover or is too young to delete still stored.
  func expectRecovered(_ harness: SyncHarness) async throws {
    #expect(harness.store.replica == replica)
    let stored = try await SyncStoredFiles.read(replica, in: world.storage)
    let entries = try await SyncCompactCheck.entries(harness)
    let liveBases = entries.filter { $0.isBase && $0.isLive }
    #expect(stored.bases.count == 1 && stored.bases.values.allSatisfy(\.isComplete), "\(stored.bases)")
    #expect(liveBases.map(\.point) == Array(stored.bases.keys) && liveBases.allSatisfy(\.isCompleteBase))
    #expect(stored.bases[olderBase] == nil)
    let liveSegments = Set(entries.filter { !$0.isBase && $0.isLive }.map(\.point))
    #expect(liveSegments == stored.segments)
    #expect(stored.segments == recent)
    #expect(try await SyncCompactCheck.row(harness) == nil)
    #expect(try await SyncCompactCheck.ownDeletes(provider.deleted, by: harness.store).isEmpty)
  }
}

private func expectFreshReaderConverges(_ world: SyncCompactWorld, _ lines: Set<Data>, _ name: String) async throws {
  let reader = try await world.started(world.harness(name, store: try world.openStore(), provider: world.storage, configuration: crashSettings))
  try await SyncCompactCheck.drain(reader)
  #expect(try await reader.digest() == (try SyncCompactCheck.reference(lines.union(try await reader.pendingLines()))), "reader \(name)")
}

private func recover(_ harness: SyncHarness) async throws {
  for _ in 0..<4 {
    let outcome = try await harness.engine.compact()
    #expect(outcome != .postponed)
    if outcome == .notNeeded { return }
  }
  throw SyncFixtureFailure("compaction did not come to rest")
}

@Suite("SyncEngine compaction crash safety")
struct SyncCompactCrashTests {
  @Test("should keep every uploaded change readable at every checkpoint and recover to exactly one complete base")
  func shouldSurviveCrashAtEveryCheckpoint() async throws {
    let dry = try await SyncCrashScenario.make()
    let probe = SyncCompactionProbe()
    let outcome = try await dry.engine(probe: probe).engine.compact(force: true)
    guard case .compacted(_, let deleted, 1) = outcome, deleted > 2 else { throw SyncFixtureFailure("the dry run did not compact: \(outcome)") }
    try await dry.expectRecovered(try await dry.engine())
    let steps = probe.steps
    #expect(steps.filter { $0 == .partPut }.count > 1)
    #expect(Set(steps) == Set(SyncCompactionStep.allCases))

    for index in steps.indices {
      let scenario = try await SyncCrashScenario.make()
      let crashing = try await scenario.engine(probe: SyncCompactionProbe(crashAt: index))
      let error = await #expect(throws: SyncError.self) { try await crashing.engine.compact(force: true) }
      guard case .corruptState("injected crash")? = error else { throw SyncFixtureFailure("expected a crash at \(index) (\(steps[index])), got \(String(describing: error))") }

      try await scenario.expectFreshReaderConverges("before-\(index)")
      let recovered = try await scenario.engine()
      try await recover(recovered)
      try await scenario.expectRecovered(recovered)
      try await scenario.expectFreshReaderConverges("after-\(index)")
    }
  }

  @Test("should keep deleting what the older base covers while a resumed base seals to the same point with another part count, never touching that point")
  func shouldCleanUpWhileResplitBaseWaits() async throws {
    let scenario = try await SyncCrashScenario.make()
    let crashing = try await scenario.engine(probe: SyncCompactionProbe(crashAt: 1))
    await #expect(throws: SyncError.self) { try await crashing.engine.compact(force: true) }
    let row = try #require(try await SyncCompactCheck.row(crashing))
    #expect(row.parts > 1)
    let covered = try await SyncCompactCheck.entries(crashing).filter { !$0.isBase && $0.isLive && $0.point.last <= scenario.olderBase.last }
    #expect(!covered.isEmpty)
    let putsBefore = scenario.provider.puts.count
    let deletesBefore = scenario.provider.deleted.count
    var resplitSettings = crashSettings
    resplitSettings.basePartBytes = BaseCodec.defaultPartPayloadBytes
    let resplit = try await scenario.engine(configuration: resplitSettings)

    let outcomes = [
      try await resplit.engine.compact(force: true), try await resplit.engine.compact(force: true), try await resplit.engine.compact(force: true),
    ]

    #expect(outcomes == [.cleaned(deletedSegments: covered.count, deletedBases: 0), .postponed, .postponed])
    let deleted = scenario.provider.deleted.dropFirst(deletesBefore)
    #expect(Set(deleted) == Set(covered.compactMap { entry in entry.first.map { VaultPath.segment(scenario.replica, first: $0, last: entry.point.last, tag: entry.point.tag) } }))
    let touched = Set(row.keys)
    #expect(!scenario.provider.puts.dropFirst(putsBefore).contains { touched.contains($0) })
    #expect(!deleted.contains { touched.contains($0) })
    #expect(try await SyncCompactCheck.row(resplit) == nil)
    let announced = try #require(try await SyncCompactCheck.entries(resplit).first { $0.isBase && $0.point == row.point })
    #expect(announced.isLive && !announced.isCompleteBase && announced.parts == row.parts)
    #expect(try await SyncStoredFiles.read(scenario.replica, in: scenario.world.storage).bases[scenario.olderBase]?.isComplete == true)
    try await scenario.expectFreshReaderConverges("resplit")
  }

  @Test("should keep an announced base that reaches beyond the current base, though a restored copy abandons it while an older base is still listed")
  func shouldKeepAbandonedBaseBeyondCurrent() async throws {
    let world = SyncCompactWorld()
    let directory = ReplicaTemporaryDirectory()
    let original = directory.database("original")
    let backup = directory.database("backup")
    let settings = SyncConfiguration(
      maximumSegmentLines: 2, compactionAge: .zero, compactionBytes: .max, compactionFiles: .max, compactionInterval: .zero, basePartBytes: 1_000)
    let provider = SyncCompactProvider(wrapping: world.storage)
    var lines: Set<Data> = []
    let writer = try await world.started(world.harness("writer", store: try world.openStore(.file(original)), provider: provider, configuration: settings), createsKey: true)
    let replica = writer.store.replica
    func send(_ prefix: String) async throws {
      try await writer.writeNotes(3, prefix: prefix) { "title \($0) \(String(repeating: "~", count: 60))" }
      lines.formUnion(try await writer.pendingLines())
      _ = try await writer.uploaded()
    }
    try await send("a")
    guard case .compacted(let older, _, 0) = try await writer.engine.compact(force: true) else { throw SyncFixtureFailure("expected the older base") }
    try await send("b")
    let crashing = world.harness("writer", store: try world.openStore(.file(original)), provider: provider, configuration: settings, probe: SyncCompactionProbe(crashAt: 1))
    _ = try await crashing.engine.start()
    await #expect(throws: SyncError.self) { try await crashing.engine.compact(force: true) }
    let announced = try #require(try await SyncCompactCheck.row(crashing))
    try ReplicaFixture.copyDatabase(from: original, to: backup)
    provider.linger(VaultPath.basePrefix(replica))
    let finisher = world.harness("writer", store: try world.openStore(.file(original)), provider: provider, configuration: settings)
    _ = try await finisher.engine.start()
    guard case .compacted(announced.point, let deletedSegments, 1) = try await finisher.engine.compact() else { throw SyncFixtureFailure("the original did not finish") }
    #expect(deletedSegments > 0)
    #expect(try await SyncStoredFiles.read(replica, in: world.storage).bases[older]?.isComplete == true)

    let restoredProvider = SyncCompactProvider(wrapping: world.storage)
    let restored = world.harness("writer", store: try world.openStore(.file(backup)), provider: restoredProvider, configuration: settings)
    #expect(try await restored.engine.start() == .alreadyRunning)
    try await restored.writeNotes(1, prefix: "late")
    lines.formUnion(try await restored.pendingLines())
    _ = try await restored.uploaded()

    _ = try await restored.engine.compact()

    #expect(try await SyncCompactCheck.row(restored) == nil)
    #expect(!restoredProvider.deleted.contains { announced.keys.contains($0) })
    #expect(try await SyncStoredFiles.read(replica, in: world.storage).bases[announced.point]?.isComplete == true)
    try await expectFreshReaderConverges(world, lines, "beyond-current")
  }

  @Test("should write nothing under the new id, drop no unsent change and postpone when the database is re-minted during a compaction")
  func shouldStopWhenReplicaChanges() async throws {
    let world = SyncCompactWorld()
    let store = try world.openStore()
    let marker = DeviceMarker(store: world.keychain.device("writer").store(service: "marker", scope: .device))
    let elsewhere = ReplicaLifecycle(store: store, vault: SyncFixture.vault, marker: marker, device: ReplicaFixture.phone, wallClock: { SyncFixture.start })
    let probe = SyncCompactionProbe(at: .deleted) {
      _ = try await store.write { transaction in try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("unsent")), ["title": .string("kept")]) }
      _ = try await elsewhere.remint(reason: .clockCorrected)
    }
    let provider = SyncCompactProvider(wrapping: world.storage)
    let harness = try await world.started(world.harness("writer", store: store, provider: provider, configuration: crashSettings, probe: probe), createsKey: true)
    for batch in 0..<3 {
      try await harness.writeNotes(2, prefix: "b\(batch)-")
      _ = try await harness.uploaded()
    }
    let old = store.replica
    world.advance(days: 20)
    let oldEntries = try await SyncCompactCheck.entries(harness, of: old)

    #expect(try await harness.engine.compact(force: true) == .postponed)

    let moved = store.replica
    #expect(moved != old)
    #expect(try await SyncCompactCheck.entries(harness, of: moved).isEmpty)
    #expect(try await SyncCompactCheck.entries(harness, of: old).filter { !$0.isBase && !$0.isLive }.isEmpty)
    #expect(try await SyncCompactCheck.entries(harness, of: old).filter { !$0.isBase } == oldEntries.filter { !$0.isBase })
    let unsent = try await harness.pendingLines().map { try ChangeRecord(json: CanonicalJSON.decode($0)) }.filter { $0.key == ReplicaFixture.key("unsent") }
    #expect(unsent.count == 1)

    _ = try await harness.uploaded()
    #expect(try await harness.pendingLines().isEmpty)
    let sent = try await harness.segments(of: moved).flatMap(\.file.lines).map { try ChangeRecord(json: CanonicalJSON.decode($0)) }
    #expect(sent.contains { $0.key == ReplicaFixture.key("unsent") })
  }

  @Test("should keep a base another copy of the database completed when the restored copy abandons its row, and remove it only once a newer base is listed")
  func shouldKeepBaseCompletedByOtherCopy() async throws {
    let world = SyncCompactWorld()
    let directory = ReplicaTemporaryDirectory()
    let original = directory.database("original")
    let backup = directory.database("backup")
    let settings = SyncConfiguration(
      maximumSegmentLines: 2, compactionAge: .zero, compactionBytes: .max, compactionFiles: .max, compactionInterval: .zero, basePartBytes: 1_000)
    let provider = SyncCompactProvider(wrapping: world.storage)
    var lines: Set<Data> = []
    let writer = try await world.started(world.harness("writer", store: try world.openStore(.file(original)), provider: provider, configuration: settings), createsKey: true)
    let replica = writer.store.replica
    for batch in 0..<2 {
      try await writer.writeNotes(3, prefix: "a\(batch)-") { "title \($0) \(String(repeating: "~", count: 60))" }
      lines.formUnion(try await writer.pendingLines())
      _ = try await writer.uploaded()
    }
    let crashing = world.harness("writer", store: try world.openStore(.file(original)), provider: provider, configuration: settings, probe: SyncCompactionProbe(crashAt: 1))
    _ = try await crashing.engine.start()
    await #expect(throws: SyncError.self) { try await crashing.engine.compact(force: true) }
    let announced = try #require(try await SyncCompactCheck.row(crashing))
    try ReplicaFixture.copyDatabase(from: original, to: backup)
    let finisher = world.harness("writer", store: try world.openStore(.file(original)), provider: provider, configuration: settings)
    _ = try await finisher.engine.start()
    guard case .compacted(announced.point, let deletedByOriginal, 0) = try await finisher.engine.compact() else { throw SyncFixtureFailure("the original did not finish its base") }
    #expect(deletedByOriginal > 0)

    let restoredProvider = SyncCompactProvider(wrapping: world.storage)
    let restored = world.harness("writer", store: try world.openStore(.file(backup)), provider: restoredProvider, configuration: settings)
    #expect(try await restored.engine.start() == .alreadyRunning)
    #expect(restored.store.replica == replica)
    #expect(try await SyncCompactCheck.row(restored) == announced)
    try await restored.writeNotes(1, prefix: "late")
    lines.formUnion(try await restored.pendingLines())
    _ = try await restored.uploaded()

    #expect(try await restored.engine.compact() == .notNeeded)

    #expect(restoredProvider.deleted.isEmpty)
    #expect(try await SyncCompactCheck.row(restored) == nil)
    #expect(try await SyncStoredFiles.read(replica, in: world.storage).bases[announced.point]?.isComplete == true)
    let kept = try #require(try await SyncCompactCheck.entries(restored).first { $0.isBase && $0.point == announced.point })
    #expect(kept.isLive && !kept.isCompleteBase && kept.parts == announced.parts)
    try await expectFreshReaderConverges(world, lines, "after-abandon")

    restoredProvider.hide(VaultPath.basePrefix(replica))
    guard case .compacted(let newer, _, 0) = try await restored.engine.compact(force: true) else { throw SyncFixtureFailure("expected the restored copy's base") }
    #expect(restoredProvider.deleted.isEmpty)
    #expect(try await SyncStoredFiles.read(replica, in: world.storage).bases[announced.point]?.isComplete == true)
    restoredProvider.reveal()
    guard case .cleaned(_, 1) = try await restored.engine.compact() else { throw SyncFixtureFailure("expected the older base to be removed") }

    #expect(Array(try await SyncStoredFiles.read(replica, in: world.storage).bases.keys) == [newer])
    #expect(try await SyncCompactCheck.ownDeletes(restoredProvider.deleted, by: restored.store).isEmpty)
    try await expectFreshReaderConverges(world, lines, "after-newer")
  }

  @Test("should forget the compaction in progress when the self-check re-mints")
  func shouldForgetCompactionOnRemint() async throws {
    let scenario = try await SyncCrashScenario.make()
    let crashing = try await scenario.engine(probe: SyncCompactionProbe(crashAt: 2))
    await #expect(throws: SyncError.self) { try await crashing.engine.compact(force: true) }
    #expect(try await SyncCompactCheck.row(crashing) != nil)
    let key = try #require(crashing.ring.writingKey())
    _ = try await SyncPlant.segment([try #require(try await crashing.store.ownSnapshot().lines.first)], replica: scenario.replica, key: key, in: scenario.world.storage)

    let recovered = try await scenario.engine()
    #expect(try await recovered.engine.compact(force: true) == .postponed)

    #expect(recovered.store.replica != scenario.replica)
    #expect(try await SyncCompactCheck.row(recovered) == nil)
    #expect(scenario.provider.deleted.isEmpty)
  }

  @Test("should delete an abandoned base's parts and finish a new base after local writes")
  func shouldAbandonStaleBase() async throws {
    var scenario = try await SyncCrashScenario.make()
    let crashing = try await scenario.engine(probe: SyncCompactionProbe(crashAt: 2))
    await #expect(throws: SyncError.self) { try await crashing.engine.compact(force: true) }
    let abandoned = try #require(try await SyncCompactCheck.row(crashing))
    #expect(try await SyncStoredFiles.read(scenario.replica, in: scenario.world.storage).bases[abandoned.point]?.present == [1])

    let recovered = try await scenario.engine()
    try await recovered.writeNotes(2, prefix: "z")
    scenario.lines.formUnion(try await recovered.pendingLines())
    _ = try await recovered.uploaded()
    let outcome = try await recovered.engine.compact(force: true)

    guard case .compacted(let base, _, _) = outcome else { throw SyncFixtureFailure("expected a new base, got \(outcome)") }
    #expect(base.last > abandoned.point.last)
    let stored = try await SyncStoredFiles.read(scenario.replica, in: scenario.world.storage)
    #expect(Array(stored.bases.keys) == [base] && stored.bases[base]?.isComplete == true)
    let entries = try await SyncCompactCheck.entries(recovered)
    #expect(entries.contains { $0.isBase && $0.point == abandoned.point && !$0.isLive })
    #expect(abandoned.keys.allSatisfy(scenario.provider.deleted.contains))
    #expect(try await SyncCompactCheck.row(recovered) == nil)
    #expect(try await SyncCompactCheck.ownDeletes(scenario.provider.deleted, by: recovered.store).isEmpty)
    try await scenario.expectFreshReaderConverges("abandoned")
  }
}
