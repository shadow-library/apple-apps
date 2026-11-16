import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

@Suite("SyncEngine adoption across peers")
struct SyncAdoptPeerTests {
  @Test("should let two adopters of one replica interleave, each publishing its fact, and leave readers with every change")
  func shouldAllowTwoAdopters() async throws {
    let scenario = try await SyncAdoptScenario.make(retire: false)
    let other = scenario.bystander
    try await scenario.adopter.lifecycle.retire(scenario.retiredID, successor: scenario.adopterID)
    try await other.lifecycle.retire(scenario.retiredID, successor: other.store.replica)
    _ = try await scenario.adopter.engine.upload()
    _ = try await other.engine.upload()
    scenario.world.advance(days: 31)
    let interleave = once {
      guard try await other.engine.adopt() == .adopted([scenario.retiredID]) else { throw SyncFixtureFailure("the second adopter did not adopt") }
    }
    let adopter = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .adoption(.folded) { try await interleave() } })

    #expect(try await adopter.engine.adopt() == .inProgress([scenario.retiredID]))
    #expect(try await adopter.engine.adopt() == .inProgress([scenario.retiredID]))
    scenario.world.advance(days: 31)
    #expect(try await adopter.engine.adopt() == .adopted([scenario.retiredID]))

    #expect(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log).isEmpty)
    _ = try await adopter.engine.sync()
    _ = try await other.engine.sync()
    _ = try await adopter.engine.sync()
    let adopters = Set(try await SyncAdoptCheck.facts(adopter).filter { $0.adopted == scenario.retiredID }.map(\.adopter))
    #expect(adopters == [scenario.adopterID, other.store.replica])
    for reader in [adopter, other] {
      #expect(try await reader.digest() == (try await scenario.reference(also: try await reader.pendingLines())))
    }
    try await scenario.expectConverges(try await scenario.freshReader("fresh"), "fresh")
    try await scenario.expectConverges(scenario.half, "half")
  }

  @Test("should start over under the new id when the adopter re-mints between publish and delete, deleting nothing before")
  func shouldAdoptAgainAfterRemint() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let old = scenario.adopterID
    let store = scenario.adopterStore
    let elsewhere = ReplicaLifecycle(
      store: store, vault: SyncFixture.vault, marker: ReplicaFixture.marker(scenario.world.keychain, "adopter"), device: ReplicaFixture.phone,
      wallClock: { SyncFixture.start })
    let remint = once { _ = try await elsewhere.remint(reason: .clockCorrected) }
    let before = Set(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log))
    let adopter = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .adoption(.uploaded) { try await remint() } })

    #expect(try await adopter.engine.adopt() == .postponed)

    #expect(store.replica != old)
    #expect(Set(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log)) == before)
    try await scenario.expectConverges(try await scenario.freshReader("between"), "between")
    #expect(try await SyncAdoptCheck.finish(adopter).first == .adopted([scenario.retiredID]))
    #expect(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log).isEmpty)
    #expect(try await SyncAdoptCheck.folds(adopter).isEmpty)
    let facts = try await SyncAdoptCheck.facts(adopter).filter { $0.adopted == scenario.retiredID }
    #expect(Set(facts.map(\.adopter)) == [old, store.replica])
    _ = try await adopter.engine.sync()
    try await scenario.expectConverges(try await scenario.freshReader("fresh"), "fresh")
    try await scenario.expectConverges(scenario.half, "half")
    try await scenario.expectConverges(scenario.bystander, "bystander")
  }

  @Test("should carry a retired replica's changes through an adopter that is itself adopted, to a reader that saw none of it")
  func shouldAdoptThroughChain() async throws {
    let scenario = try await SyncAdoptScenario.make()
    #expect(try await scenario.adopter.engine.adopt() == .adopted([scenario.retiredID]))
    let second = scenario.bystander
    _ = try await second.engine.sync()
    try await second.lifecycle.retire(scenario.adopterID, successor: second.store.replica)
    _ = try await second.engine.upload()
    scenario.world.advance(days: 31)

    #expect(try await second.engine.adopt() == .adopted([scenario.adopterID]))

    #expect(try await SyncAdoptCheck.stored(under: scenario.adopterID, in: scenario.log).isEmpty)
    let lines = try await SyncAdoptCheck.baseLines(of: second.store.replica, in: scenario.log, ring: second.ring)
    let keys = Set(try lines.compactMap { try? ChangeRecord(json: CanonicalJSON.decode($0)) }.filter { $0.clock.replica == scenario.retiredID }.map(\.key.rawValue))
    #expect(keys.isSuperset(of: ["r1-0", "r2-0", "r3-0"]))
    try await scenario.expectConverges(try await scenario.freshReader("unseen"), "unseen")
    try await scenario.expectConverges(scenario.half, "half")
  }

  @Test("should keep newer-schema content of the adopted files byte for byte in the adopter's base, for a reader running the newer registry")
  func shouldKeepNewerSchemaContent() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let sketch = ReplicaFixture.kind("sketch")
    let newer = SyncKernelSchema.registry(
      version: 4,
      adding: [
        EntitySchema(kind: SyncFixture.note, shape: .record(fields: ["title": .register, "mood": .register]), syncClass: .general),
        EntitySchema(kind: SyncFixture.vital, shape: .record(fields: ["value": .register]), syncClass: .health),
        EntitySchema(kind: sketch, shape: .record(fields: ["shape": .register]), syncClass: .general),
      ])
    let writer = try SyncFixture.open(registry: newer, wallClock: { scenario.world.clock.now })
    _ = try await writer.write { transaction in
      _ = try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("future-note")), ["title": .string("kept"), "mood": .string("bright")])
      _ = try transaction.set(EntityRef(kind: sketch, key: ReplicaFixture.key("future-sketch")), ["shape": .string("spiral")])
    }
    let records = try await writer.pendingChanges(limit: .max).map(\.line)
    let opaque = CanonicalJSON.encode(.object(["format": .string("from a later app")]))
    let future = writer.replica
    _ = try await SyncPlant.segment(records + [opaque], replica: future, key: try #require(scenario.adopter.ring.writingKey()), in: scenario.log)
    try await scenario.adopter.lifecycle.retire(future, successor: scenario.adopterID)
    scenario.world.advance(days: 31)

    #expect(try await SyncAdoptCheck.finish(scenario.adopter).first == .adopted([future, scenario.retiredID].sorted()))

    #expect(try await SyncAdoptCheck.stored(under: future, in: scenario.log).isEmpty)
    let base = Set(try await SyncAdoptCheck.baseLines(of: scenario.adopterID, in: scenario.log, ring: scenario.adopter.ring))
    #expect(base.contains(records[1]) && base.contains(opaque))
    let reader = try await scenario.world.started(
      scenario.world.harness("newer", store: try scenario.world.openStore(registry: newer), provider: scenario.log, configuration: scenario.settings))
    try await SyncCompactCheck.drain(reader)
    let expected = try SyncAdoptCheck.reference(scenario.log, ring: reader.ring, registry: newer, extra: try await reader.pendingLines())
    #expect(try await reader.digest() == expected)
    let noteRef = EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("future-note"))
    guard case .record(let note)? = try await reader.store.read({ try $0.state(of: noteRef) }) else { throw SyncFixtureFailure("the newer reader lacks the note") }
    #expect(note[field: "mood"]?.value == .string("bright"))
    #expect(try await reader.store.loadState(.vault).opaqueLines.contains(opaque))
  }

  @Test("should volunteer only where the successor chain ends, and nowhere else")
  func shouldVolunteerAtEndOfChain() async throws {
    let scenario = try await SyncAdoptScenario.make(retire: false)
    let (adopter, other) = (scenario.adopter, scenario.bystander)
    let skipped = ReplicaID(UUID.v7())
    try await adopter.lifecycle.retire(scenario.retiredID, successor: skipped)
    try await adopter.lifecycle.retire(skipped, successor: other.store.replica)
    for peer in [adopter, other, adopter] { _ = try await peer.engine.sync() }
    scenario.world.advance(days: 31)

    #expect(try await adopter.engine.adopt() == .nothingToAdopt)
    #expect(try await SyncAdoptCheck.folds(adopter).isEmpty)
    #expect(try await other.engine.adopt() == .adopted([scenario.retiredID]))
  }

  @Test("should leave a replica whose chain ends at no active replica to the lowest active id alone")
  func shouldVolunteerAsLowestActive() async throws {
    let scenario = try await SyncAdoptScenario.make(retire: false)
    let peers = [scenario.adopter, scenario.bystander, scenario.half]
    let dead = ReplicaID(UUID.v7())
    try await scenario.adopter.lifecycle.retire(scenario.retiredID, successor: dead)
    try await scenario.adopter.lifecycle.retire(dead)
    for _ in 0..<2 {
      for peer in peers { _ = try await peer.engine.sync() }
    }
    scenario.world.advance(days: 31)
    let active = try await scenario.adopter.lifecycle.directory().replicas.filter { $0.state == .active }.map(\.replica)
    let lowest = try #require(active.min())
    #expect(Set(active) == Set(peers.map(\.store.replica)))

    for peer in peers.sorted(by: { $0.store.replica > $1.store.replica }) {
      let outcome = try await peer.engine.adopt()
      #expect(outcome == (peer.store.replica == lowest ? .adopted([scenario.retiredID]) : .nothingToAdopt))
    }
    #expect(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log).isEmpty)
  }

  @Test("should fold nothing before the adoption delay has passed since the retirement")
  func shouldWaitForDelay() async throws {
    let scenario = try await SyncAdoptScenario.make(retire: false)
    try await scenario.adopter.lifecycle.retire(scenario.retiredID, successor: scenario.adopterID)
    let retired = try #require(try await scenario.adopter.lifecycle.directory().entry(for: scenario.retiredID)?.retired)
    #expect(retired == Int64(scenario.world.clock.now.timeIntervalSince1970 * 1_000))
    scenario.world.advance(days: 29.9)

    #expect(try await scenario.adopter.engine.adopt() == .nothingToAdopt)
    #expect(try await SyncAdoptCheck.folds(scenario.adopter).isEmpty)
    #expect(try await SyncAdoptCheck.rows(scenario.adopter).isEmpty)

    scenario.world.advance(days: 0.2)
    #expect(try await scenario.adopter.engine.adopt() == .adopted([scenario.retiredID]))
  }
}
