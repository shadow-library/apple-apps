import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let other = SchemaFixture.otherNovel

private struct Rank: Comparable {
  let ordinal: Int
  let key: [UInt16]

  init(_ ordinal: Int, _ key: String) {
    self.ordinal = ordinal
    self.key = Array(key.utf16)
  }

  static func < (left: Rank, right: Rank) -> Bool {
    left.ordinal != right.ordinal ? left.ordinal < right.ordinal : left.key.lexicographicallyPrecedes(right.key)
  }
}

private func expectedStates(_ volumes: [VolumeRecord]) -> [String: String] {
  let reached = volumes.filter(\.goalMet).map { Rank($0.ordinal, $0.volume) }.max()
  let candidates = volumes.filter { volume in !volume.goalMet && reached.map { Rank(volume.ordinal, volume.volume) > $0 } != false }
  let active = candidates.min { Rank($0.ordinal, $0.volume) < Rank($1.ordinal, $1.volume) }?.volume
  return Dictionary(uniqueKeysWithValues: volumes.map { ($0.volume, $0.goalMet ? "goal_met" : $0.volume == active ? "active" : "not_started") })
}

private func table(_ novel: UUID, in store: VaultStore) async throws -> [String: String] {
  let entries = try await Projection.fetch(VolumeStateDerivation.request(for: novel), in: store)
  return Dictionary(uniqueKeysWithValues: entries.map { ($0.volume, $0.state.rawValue) })
}

private func ordinals(_ novel: UUID, in store: VaultStore) async throws -> [String: Int] {
  let entries = try await Projection.fetch(VolumeStateDerivation.request(for: novel), in: store)
  return Dictionary(uniqueKeysWithValues: entries.map { ($0.volume, $0.ordinal) })
}

private func volume(_ key: String, _ ordinal: Int, goalMet: Bool = false, of owner: UUID = novel) -> VolumeRecord {
  VolumeRecord(novel: owner, volume: key, ordinal: ordinal, goalMet: goalMet)
}

private func create(_ volumes: [VolumeRecord], in store: VaultStore) async throws {
  for record in volumes { _ = try await Projection.write(store) { transaction in try record.create(in: &transaction) } }
}

private func setGoalMet(_ key: String, _ met: Bool, of owner: UUID = novel, in store: VaultStore) async throws {
  var edit = VolumeEdit()
  edit.goalMet = .set(met)
  let changes = edit
  _ = try await Projection.write(store) { transaction in try VolumeRecord.edit(novel: owner, volume: key, changes, in: &transaction) }
}

@Suite("Volume state derivation", .timeLimit(.minutes(2)))
struct VolumeStateDerivationTests {
  @Test
  func shouldHoldNothingForANovelWithoutVolumes() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await Projection.createNovel(novel, in: store)
    #expect(try await table(novel, in: store).isEmpty)
  }

  @Test
  func shouldActivateTheLowestOrdinalAndLeaveTheRestNotStarted() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("three", 3), volume("one", 1), volume("two", 2)], in: store)
    #expect(try await table(novel, in: store) == ["one": "active", "two": "not_started", "three": "not_started"])
  }

  @Test
  func shouldMoveTheActiveStatePastEachGoalMetVolume() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("one", 1), volume("two", 2), volume("three", 3)], in: store)
    try await setGoalMet("one", true, in: store)
    #expect(try await table(novel, in: store) == ["one": "goal_met", "two": "active", "three": "not_started"])
    try await setGoalMet("two", true, in: store)
    try await setGoalMet("three", true, in: store)
    #expect(try await table(novel, in: store) == ["one": "goal_met", "two": "goal_met", "three": "goal_met"])
  }

  @Test
  func shouldNeverActivateAVolumeBelowAGoalMetOne() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("one", 1), volume("two", 2, goalMet: true), volume("three", 3)], in: store)
    #expect(try await table(novel, in: store) == ["one": "not_started", "two": "goal_met", "three": "active"])
  }

  @Test
  func shouldReopenAVolumeWhenItsGoalIsUnmarked() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("one", 1), volume("two", 2)], in: store)
    try await setGoalMet("one", true, in: store)
    try await setGoalMet("one", false, in: store)
    #expect(try await table(novel, in: store) == ["one": "active", "two": "not_started"])
  }

  @Test
  func shouldBreakOrdinalTiesByKeyOnEveryDevice() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("b", 0), volume("a", 0), volume("c", 0)], in: store)
    #expect(try await table(novel, in: store) == ["a": "active", "b": "not_started", "c": "not_started"])
    try await setGoalMet("a", true, in: store)
    #expect(try await table(novel, in: store) == ["a": "goal_met", "b": "active", "c": "not_started"])
  }

  @Test
  func shouldBreakTiesByUTF16CodeUnitsNotBytes() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("\u{E000}", 0), volume("\u{1F600}", 0)], in: store)
    #expect(try await table(novel, in: store) == ["\u{1F600}": "active", "\u{E000}": "not_started"])
  }

  @Test
  func shouldFollowAnOrdinalEditAndTheOrdinalColumn() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("one", 1), volume("two", 2)], in: store)
    var edit = VolumeEdit()
    edit.ordinal = .set(0)
    let changes = edit
    _ = try await Projection.write(store) { transaction in try VolumeRecord.edit(novel: novel, volume: "two", changes, in: &transaction) }
    #expect(try await table(novel, in: store) == ["one": "not_started", "two": "active"])
    #expect(try await ordinals(novel, in: store) == ["one": 1, "two": 0])
  }

  @Test
  func shouldDropARemovedVolumeAndBringItBackOnRestore() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("one", 1), volume("two", 2)], in: store)
    _ = try await Projection.write(store) { transaction in try VolumeRecord.remove(novel: novel, volume: "one", in: &transaction) }
    #expect(try await table(novel, in: store) == ["two": "active"])
    _ = try await Projection.write(store) { transaction in try volume("one", 1).restore(in: &transaction) }
    #expect(try await table(novel, in: store) == ["one": "active", "two": "not_started"])
  }

  @Test
  func shouldDropAPurgedVolume() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("one", 1), volume("two", 2)], in: store)
    try await Projection.purge(VolumeRecord.ref(novel: novel, volume: "one"), in: store)
    #expect(try await table(novel, in: store) == ["two": "active"])
    try await Projection.purge(VolumeRecord.ref(novel: novel, volume: "two"), in: store)
    #expect(try await table(novel, in: store).isEmpty)
  }

  @Test
  func shouldKeepNovelsApart() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("one", 1), volume("two", 2), volume("one", 5, of: other)], in: store)
    try await setGoalMet("one", true, in: store)
    #expect(try await table(novel, in: store) == ["one": "goal_met", "two": "active"])
    #expect(try await table(other, in: store) == ["one": "active"])
  }

  @Test
  func shouldSkipAVolumeItCannotReadWithoutAFault() async throws {
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler)
    try await create([volume("two", 2)], in: store)
    try await Projection.set(VolumeRecord.ref(novel: novel, volume: "one"), ["ordinal": .string("not a number")], in: store)
    #expect(try await table(novel, in: store) == ["two": "active"])
    #expect(try await Projection.faults(reconciler, in: store).isEmpty)
    let comparison = try await Projection.compare(reconciler, in: store)
    #expect(comparison.incremental == comparison.rebuilt)
  }

  @Test
  func shouldReadTheStandingsTheOperationsSee() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await create([volume("one", 1), volume("two", 2)], in: store)
    let advance = try await store.write { transaction in try Volumes.markGoalMet(novel: novel, volume: "one", in: &transaction) }
    #expect(advance.activated == "two")
    #expect(try await table(novel, in: store) == ["one": "goal_met", "two": "active"])
  }
}

private enum StoryOperations {
  static let keys = ["one", "two", "three", "\u{1F600}", "\u{E000}"]

  static func volume(_ generator: inout SeededGenerator, _ universe: ProjectionUniverse, ordinals: ClosedRange<Int> = 0...4) -> VolumeRecord {
    VolumeRecord(
      novel: universe.novel(&generator), volume: generator.pick(from: keys), ordinal: generator.int(in: ordinals), title: universe.text(&generator), goalMet: generator.chance(0.25)
    )
  }

  static let volumes: [ProjectionOperation] = [
    ProjectionOperation(name: "create volume with a goal flag", weight: 3) { generator, universe in
      let record = volume(&generator, universe)
      return { transaction in _ = try record.create(in: &transaction) }
    },
    ProjectionOperation(name: "reorder volume", weight: 3) { generator, universe in
      let record = volume(&generator, universe)
      var edit = VolumeEdit()
      edit.ordinal = .set(generator.int(in: 0...4))
      let changes = edit
      return { transaction in _ = try VolumeRecord.edit(record.ref, changes.fields, in: &transaction) }
    },
    ProjectionOperation(name: "retitle volume", weight: 2) { generator, universe in
      let record = volume(&generator, universe)
      var edit = VolumeEdit()
      edit.title = .set(universe.text(&generator))
      edit.objective = .set(universe.text(&generator))
      let changes = edit
      return { transaction in _ = try VolumeRecord.edit(record.ref, changes.fields, in: &transaction) }
    },
    ProjectionOperation(name: "toggle goal met", weight: 4) { generator, universe in
      let record = volume(&generator, universe)
      var edit = VolumeEdit()
      edit.goalMet = .set(generator.chance(0.5))
      let changes = edit
      return { transaction in _ = try VolumeRecord.edit(record.ref, changes.fields, in: &transaction) }
    },
    ProjectionOperation(name: "mark the active volume goal met", weight: 2) { generator, universe in
      let (owner, key) = (universe.novel(&generator), generator.pick(from: keys))
      return { transaction in _ = try? Volumes.markGoalMet(novel: owner, volume: key, in: &transaction) }
    },
    ProjectionOperation(name: "remove volume", weight: 2) { generator, universe in
      let ref = volume(&generator, universe).ref
      return { transaction in _ = try VolumeRecord.remove(ref, in: &transaction) }
    },
    ProjectionOperation(name: "restore volume", weight: 2) { generator, universe in
      let record = volume(&generator, universe)
      return { transaction in _ = try record.restore(in: &transaction) }
    },
    ProjectionOperation(name: "purge volume", weight: 1) { generator, universe in
      let ref = volume(&generator, universe).ref
      let purges = generator.chance(0.3)
      return { transaction in if purges { _ = try transaction.purge(ref) } }
    },
    ProjectionOperation(name: "write an unreadable volume", weight: 1) { generator, universe in
      let ref = volume(&generator, universe).ref
      return { transaction in _ = try transaction.set(ref, ["ordinal": .string("x")]) }
    },
  ]
}

private func volumeOracle(_ reconciler: NovelForgeReconciler, _ store: VaultStore, _ universe: ProjectionUniverse) async throws {
  for owner in universe.novels {
    let volumes = try await store.read { transaction in try VolumeRecord.listing(novel: owner, in: transaction).live }
    guard try await table(owner, in: store) == expectedStates(volumes) else { throw ProjectionPropertyFailure.oracle("volume states of \(owner)") }
    guard try await ordinals(owner, in: store) == Dictionary(uniqueKeysWithValues: volumes.map { ($0.volume, $0.ordinal) }) else {
      throw ProjectionPropertyFailure.oracle("volume ordinals of \(owner)")
    }
  }
}

@Suite("Volume state property", .timeLimit(.minutes(5)))
struct VolumeStatePropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldMatchARebuildAndTheOracleAcrossReplicas(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(operations: ProjectionOperations.novels + StoryOperations.volumes, iterations: 8, steps: 36, settled: volumeOracle)
    try await property.check(order: order, seed: order == .causal ? 0xD18A1 : 0xD18A2)
  }

  @Test
  func shouldBeInTheStandardCatalogue() {
    #expect(NovelForgeDerivations.standard.contains { $0 is VolumeStateDerivation })
  }
}
