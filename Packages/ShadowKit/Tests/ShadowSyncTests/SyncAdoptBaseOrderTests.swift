import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private struct SyncBaseOrderWorld {
  let world: SyncCompactWorld
  let store: VaultStore
  let provider: SyncCompactProvider
  let writer: SyncHarness
  let foreign: VaultStore

  static func make() async throws -> SyncBaseOrderWorld {
    let world = SyncCompactWorld()
    let store = try world.openStore()
    let provider = SyncCompactProvider(wrapping: world.storage)
    let writer = try await world.started(world.harness("writer", store: store, provider: provider, configuration: adoptSettings), createsKey: true)
    try await writer.writeNotes(3, title: SyncAdoptScenario.title("own"))
    _ = try await writer.uploaded()
    return SyncBaseOrderWorld(world: world, store: store, provider: provider, writer: writer, foreign: try world.openStore())
  }

  /// Merges another replica's writes into the own writes without moving the sequence number, as a fold does.
  func fold(_ prefix: String) async throws {
    _ = try await foreign.write { transaction in
      try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key(prefix)), ["title": .string(SyncAdoptScenario.title(prefix)(0))])
    }
    _ = try await store.adoptRemote(try await foreign.pendingChanges(limit: .max).map(\.line))
  }

  func harness(probe: SyncCompactionProbe = SyncCompactionProbe()) async throws -> SyncHarness {
    let harness = world.harness("writer", store: store, provider: provider, configuration: adoptSettings, probe: probe)
    _ = try await harness.engine.start()
    return harness
  }
}

@Suite("SyncEngine compaction at an equal sequence number")
struct SyncAdoptBaseOrderTests {
  @Test("should delete a base at the same upTo once a base completed after it is current")
  func shouldSupersedeBaseCompletedEarlier() async throws {
    let setup = try await SyncBaseOrderWorld.make()
    guard case .compacted(let older, _, 0) = try await setup.writer.engine.compact(force: true) else { throw SyncFixtureFailure("expected the first base") }
    try await setup.fold("adopted")

    guard case .compacted(let newer, _, 1) = try await setup.writer.engine.compact(force: true) else { throw SyncFixtureFailure("expected a base that supersedes") }

    #expect(newer.last == older.last && newer != older)
    #expect(Array(try await SyncStoredFiles.read(setup.store.replica, in: setup.world.storage).bases.keys) == [newer])
  }

  @Test("should keep a base announced at the same upTo and never completed until a base with a higher upTo is current")
  func shouldKeepAnnouncedBaseAtSameUpTo() async throws {
    let setup = try await SyncBaseOrderWorld.make()
    guard case .compacted(let older, _, 0) = try await setup.writer.engine.compact(force: true) else { throw SyncFixtureFailure("expected the first base") }
    try await setup.fold("first")
    let crashing = try await setup.harness(probe: SyncCompactionProbe(crashAt: 2))
    await #expect(throws: SyncError.self) { try await crashing.engine.compact(force: true) }
    let announced = try #require(try await SyncCompactCheck.row(crashing))
    #expect(announced.point.last == older.last)
    try await setup.fold("second")
    let writer = try await setup.harness()

    guard case .compacted(let current, _, 1) = try await writer.engine.compact(force: true) else { throw SyncFixtureFailure("expected a base at the same upTo") }

    #expect(current.last == older.last && current != announced.point)
    let stored = try await SyncStoredFiles.read(setup.store.replica, in: setup.world.storage)
    #expect(stored.bases[older] == nil)
    #expect(stored.bases[announced.point]?.present.contains(1) == true)
    let entry = try #require(try await SyncCompactCheck.entries(writer).first { $0.isBase && $0.point == announced.point })
    #expect(entry.isLive && !entry.isCompleteBase)
    #expect(!setup.provider.deleted.contains { announced.keys.contains($0) })

    try await writer.writeNotes(1, prefix: "later")
    _ = try await writer.uploaded()
    guard case .compacted(let higher, _, 2) = try await writer.engine.compact(force: true) else { throw SyncFixtureFailure("expected the higher base to remove both") }
    #expect(Array(try await SyncStoredFiles.read(setup.store.replica, in: setup.world.storage).bases.keys) == [higher])
  }
}
