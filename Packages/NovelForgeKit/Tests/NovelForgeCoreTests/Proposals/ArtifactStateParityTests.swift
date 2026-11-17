import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

struct ArtifactStateParityTests {
  private static func seeded(_ world: ArtifactStateWorld) async throws -> VaultStore {
    let store = try SchemaFixture.store()
    for record in try world.records() { try await store.write { transaction in try record.create(in: &transaction) } }
    return store
  }

  @Test func shouldReproduceTheReferenceStatesOfEveryRefOverTheSameRecords() async throws {
    let worlds = try ArtifactStateWorld.load()
    #expect(worlds.count >= 100)
    var mismatches: [String] = []
    var hashed = 0
    for (index, world) in worlds.enumerated() {
      let store = try await Self.seeded(world)
      let novel = world.novel
      let refs = world.refs
      let states = try await store.read { try ArtifactStateLoader.states(refs: refs, novel: novel, in: $0) }
      for expected in world.expectedStates {
        let actual = states[JSString(expected.ref)] ?? .missing
        let hash = world.statelessVolumeHash[expected.ref] ?? expected.hash
        if actual.contentHash != nil { hashed += 1 }
        let sameHash = actual.contentHash.map { $0 == hash } ?? (hash == nil)
        if actual.exists != expected.exists || !sameHash || actual.revision != nil { mismatches.append("world \(index) \(expected.ref)") }
      }
    }
    #expect(hashed > 400)
    #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(3))")
  }

  @Test func shouldReproduceTheReferenceVolumeHashWhenTheStateIsNotStarted() async throws {
    var checked = 0
    for world in try ArtifactStateWorld.load() {
      let notStarted = Set(world.rows("volumes").filter { $0.string("state") == "not_started" }.compactMap { $0.string("volumeKey").map { "volume:\($0)" } })
      let hashes = Dictionary(world.expectedStates.map { ($0.ref, $0.hash) }) { first, _ in first }
      for ref in notStarted where hashes[ref] != nil {
        #expect(hashes[ref] ?? nil == world.statelessVolumeHash[ref])
        checked += 1
      }
    }
    #expect(checked > 5)
  }

  @Test func shouldReproduceTheReferenceCurrentRecords() async throws {
    var mismatches: [String] = []
    var compared = 0
    for (index, world) in try ArtifactStateWorld.load().enumerated() {
      let store = try await Self.seeded(world)
      let novel = world.novel
      let refs = world.refs
      let current = try await store.read { try ArtifactStateLoader.currentRecords(refs: refs, novel: novel, in: $0) }
      let expected = world.expectedCurrent
      for entry in expected {
        compared += 1
        if current[entry.ref] != .fields(entry.fields) { mismatches.append("world \(index) \(entry.ref)") }
      }
      for ref in Set(refs) where current.exists(ref) && !expected.contains(where: { $0.ref == ref }) { mismatches.append("world \(index) extra \(ref)") }
    }
    #expect(compared > 300)
    #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(3))")
  }

  @Test func shouldReproduceTheReferenceProposalCurrentValues() async throws {
    var mismatches: [String] = []
    var compared = 0
    for (index, world) in try ArtifactStateWorld.load().enumerated() where world.changeSetText != "[]" {
      let store = try await Self.seeded(world)
      let novel = world.novel
      let ops = try parseChangeSet(try OrderedJSON(parsing: world.changeSetText), options: ChangeSetValidationOptions(entityMaterialization: false))
      guard currentRefs(ops) == world.currentRefs else {
        mismatches.append("world \(index) refs")
        continue
      }
      let refs = currentRefs(ops)
      let records = try await store.read { try ArtifactStateLoader.currentRecords(refs: refs, novel: novel, in: $0) }
      let actual = proposalCurrent(ops, records: records)
      compared += actual.count
      if actual != world.expectedProposalCurrent { mismatches.append("world \(index)") }
    }
    #expect(compared > 150)
    #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(3))")
  }
}
