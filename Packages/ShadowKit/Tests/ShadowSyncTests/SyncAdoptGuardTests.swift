import Foundation
import GRDB
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private func remintElsewhere(_ store: VaultStore, _ world: SyncCompactWorld, device: String, mode: RemintMode = .keepState) -> @Sendable () async throws -> Void {
  let lifecycle = ReplicaLifecycle(
    store: store, vault: SyncFixture.vault, marker: ReplicaFixture.marker(world.keychain, device), device: ReplicaFixture.phone, wallClock: { SyncFixture.start })
  return once { _ = try await lifecycle.remint(reason: .clockCorrected, mode: mode) }
}

private func foldCount(_ store: VaultStore) async throws -> Int {
  try await store.read { try Int.fetchOne($0.database, sql: "SELECT COUNT(*) FROM sync_adoption_fold") ?? 0 }
}

@Suite("SyncEngine adoption guards")
struct SyncAdoptGuardTests {
  @Test("should fold nothing into the new id when the database is re-minted between two folds")
  func shouldStopFoldingAfterRemint() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let old = scenario.adopterID
    let remint = remintElsewhere(scenario.adopterStore, scenario.world, device: "adopter")
    let adopter = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .adoption(.folded) { try await remint() } })

    #expect(try await adopter.engine.adopt() == .postponed)

    #expect(scenario.adopterStore.replica != old)
    #expect(try await foldCount(scenario.adopterStore) == 1)
    let own = try await scenario.adopterStore.ownSnapshot().lines.compactMap { try? ChangeRecord(json: CanonicalJSON.decode($0)) }
    #expect(!own.contains { $0.clock.replica == scenario.retiredID })
    #expect(Set(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log)).count > 1)
  }

  @Test("should stop folding a replica the vault no longer shows as retired, though the call began with it retired")
  func shouldRecheckRetirementInFold() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let retired = scenario.retiredID
    let store = scenario.adopterStore
    let forget = once {
      _ = try await store.write { transaction in
        try transaction.database.execute(sql: "DELETE FROM field_state WHERE scope = 0 AND kind = '_replica' AND key = ?", arguments: [retired.description])
      }
    }
    let before = Set(try await SyncAdoptCheck.stored(under: retired, in: scenario.log))
    let adopter = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .adoption(.folded) { try await forget() } })

    #expect(try await adopter.engine.adopt() == .inProgress([retired]))

    #expect(try await foldCount(store) == 1)
    #expect(try await SyncAdoptCheck.facts(adopter).isEmpty)
    #expect(Set(try await SyncAdoptCheck.stored(under: retired, in: scenario.log)) == before)
  }

  @Test("should postpone, not fail, a fold that races another engine's publish on the same database, and leave the published fact to finish")
  func shouldPostponeFoldRacingPublish() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let interrupted = SyncAdoptProbe { step in if step == .adoption(.published) { throw SyncFixtureFailure("stopped after publishing") } }
    let race = once {
      let other = try await scenario.engine(probe: interrupted)
      guard (try? await other.engine.adopt()) == nil else { throw SyncFixtureFailure("the other engine did not stop after publishing") }
    }
    let adopter = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .adoption(.folded) { try await race() } })

    #expect(try await adopter.engine.adopt() == .postponed)

    #expect(try await SyncAdoptCheck.rows(adopter)[scenario.retiredID]?.phase == .published)
    #expect(try await scenario.adopter.engine.adopt() == .adopted([scenario.retiredID]))
    try await scenario.expectAdopted(by: scenario.adopter)
    try await scenario.expectConverges(try await scenario.freshReader("fresh"), "fresh")
  }

  @Test("should not drop the re-minted id's changes when a re-mint lands between recording an upload and dropping it")
  func shouldGuardDropAgainstRemint() async throws {
    let world = SyncCompactWorld()
    let store = try world.openStore()
    let harness = try await world.started(world.harness("writer", store: store, configuration: adoptSettings), createsKey: true)
    try await harness.writeNotes(2, prefix: "sent")
    let old = store.replica
    let remint = remintElsewhere(store, world, device: "writer", mode: .rebuild)
    let checkpoint: @Sendable (SyncUploadStep) async throws(SyncError) -> Void = { step async throws(SyncError) in
      guard step == .recorded else { return }
      do {
        try await remint()
      } catch {
        throw .corruptState("the seam failed: \(error)")
      }
    }
    let engine = SyncEngine(
      store: store, provider: harness.provider, vault: SyncFixture.vault, ring: harness.ring, lifecycle: harness.lifecycle, trustedClock: harness.trustedClock,
      configuration: adoptSettings, wallClock: { world.clock.now }, publicFloor: { nil }, checkpoint: checkpoint)
    _ = try await engine.start()

    #expect(try await engine.upload() == .postponed)

    #expect(store.replica != old)
    let pending = try await harness.pendingLines().map { try ChangeRecord(json: CanonicalJSON.decode($0)) }
    #expect(pending.contains { $0.key == ReplicaFixture.key("sent0") && $0.clock.replica == store.replica })
  }

  @Test("should still delete a manifest a late delete left as the only file under an adopted prefix")
  func shouldDeleteManifestLeftBehind() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let retired = scenario.retiredID
    scenario.adopterProvider.linger(VaultPath.replicaPrefix(retired))

    #expect(try await scenario.adopter.engine.adopt() == .inProgress([retired]))

    let manifest = VaultPath.manifest(retired)
    try await scenario.log.delete(try await SyncAdoptCheck.stored(under: retired, in: scenario.log).filter { $0 != manifest })
    #expect(try await SyncAdoptCheck.stored(under: retired, in: scenario.log) == [manifest])
    #expect(try await SyncAdoptCheck.folds(scenario.adopter).isEmpty)
    let adopter = try await scenario.engine(provider: SyncCompactProvider(wrapping: scenario.log))

    #expect(try await adopter.engine.adopt() == .adopted([retired]))

    #expect(try await SyncAdoptCheck.stored(under: retired, in: scenario.log).isEmpty)
    #expect(try await SyncAdoptCheck.rows(adopter)[retired]?.phase == .finished)
    #expect(try await adopter.engine.adopt() == .nothingToAdopt)
  }
}
