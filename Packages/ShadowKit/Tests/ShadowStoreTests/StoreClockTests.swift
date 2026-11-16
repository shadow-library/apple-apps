import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))

private func isStrictlyIncreasing(_ clocks: [HLCTimestamp]) -> Bool {
  zip(clocks, clocks.dropFirst()).allSatisfy { $0 < $1 }
}

@Suite("VaultStore clocks")
struct StoreClockTests {
  @Test("should issue strictly increasing clocks across transactions and reopening while the wall clock jumps backwards")
  func shouldIssueIncreasingClocks() async throws {
    try await forAll(iterations: 30) { generator in
      let directory = TemporaryDirectory()
      let clock = ManualClock()
      var issued = [HLCTimestamp]()
      for _ in 0..<generator.int(in: 1...4) {
        let store = try StoreFixture.open(at: .file(directory.storeURL), clock: clock)
        for _ in 0..<generator.int(in: 1...4) {
          let count = generator.int(in: 1...3)
          issued += try await store.write { transaction in try (0..<count).map { try transaction.set(note, ["title": .int(Int64($0))]).clock } }
          clock.advance(by: generator.pick(from: [-86_400, -1, 0, 0, 0.000_5, 0.001, 2]))
        }
        clock.advance(by: generator.pick(from: [-3_600, 0, 0.001]))
      }
      try #require(isStrictlyIncreasing(issued))
    }
  }

  @Test("should order clock text exactly as clocks, which the kernel's SQL comparisons rely on")
  func shouldOrderClockTextLikeClocks() throws {
    try forAll(iterations: 300) { generator in
      let replicas = Fixture.replicas + [ReplicaID(UUID.v7())]
      let walls = [0, 1, 999, 1_000, 86_399_999, 1_700_000_000_000, HLCTimestamp.maxWallMillis]
      let make = { (generator: inout SeededGenerator) in
        let wall = generator.chance(0.5) ? generator.pick(from: walls) : Int64(generator.int(in: 0...Int(HLCTimestamp.maxWallMillis)))
        return must(HLCTimestamp(wallMillis: wall, counter: UInt16(generator.pick(from: [0, 1, 15, 16, 255, 4_096, 65_535])), replica: generator.pick(from: replicas)), "clock")
      }
      let first = make(&generator)
      let twin = must(HLCTimestamp(wallMillis: first.wallMillis, counter: first.counter, replica: generator.pick(from: replicas)), "twin")
      let second = generator.chance(0.3) ? twin : make(&generator)
      try #require((first < second) == first.description.utf8.lexicographicallyPrecedes(second.description.utf8))
      try #require(first.description.utf8.count == 66)
    }
  }

  @Test("should give a local write a clock above every clock already applied to the vault scope")
  func shouldWriteAboveAppliedClocks() async throws {
    try await forAll(iterations: 100) { generator in
      var factory = ChangeFactory()
      var remote = factory.changes(&generator)
      if generator.chance(0.5) {
        let future = must(HLCTimestamp(wallMillis: ManualClock().millis + 86_400_000, counter: UInt16(generator.int(in: 0...65_535)), replica: Fixture.replicas[2]), "future")
        remote.append(Fixture.change(.set, Fixture.note, Fixture.key("k3"), clock: future, fields: ["title": "future"], id: Fixture.uuid(&generator)))
      }
      let store = try StoreFixture.open(Fixture.v2)
      try await store.apply(remote)
      let local = try await store.write { transaction in try transaction.set(EntityRef(kind: Fixture.note, key: Fixture.key("fresh")), ["origin": "local"]) }
      try #require(remote.allSatisfy { $0.clock < local.clock })
    }
  }

  @Test("should keep a local write above remote clocks after reopening")
  func shouldRememberObservedClocks() async throws {
    let directory = TemporaryDirectory()
    let clock = ManualClock()
    let future = must(HLCTimestamp(wallMillis: clock.millis + 86_400_000, counter: 7, replica: Fixture.replicas[1]), "future")
    do {
      let store = try StoreFixture.open(at: .file(directory.storeURL), clock: clock)
      try await store.apply([Fixture.change(.set, Fixture.note, note.key, clock: future, fields: ["title": "remote"])])
    }
    let reopened = try StoreFixture.open(at: .file(directory.storeURL), clock: clock)
    let local = try await reopened.write { transaction in try transaction.set(note, ["title": "local"]) }
    #expect(local.clock > future)
    guard case .record(let state) = try await reopened.read({ try $0.state(of: note) }) else { throw StoreTestFailure.unexpectedState }
    #expect(state[field: "title"]?.value == "local")
  }

  @Test("should persist no clock from a transaction that rolled back, yet keep issuing above it in memory")
  func shouldIgnoreRolledBackClocks() async throws {
    let clock = ManualClock()
    let store = try StoreFixture.open(clock: clock)
    let first = try await store.write { transaction in try transaction.set(note, ["title": "a"]) }
    clock.advance(by: 60)
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in
        _ = try transaction.set(note, ["title": "lost"])
        throw StoreTestFailure.unexpectedState
      }
    }
    clock.advance(by: -120)
    let second = try await store.write { transaction in try transaction.set(note, ["title": "b"]) }
    #expect(first.clock < second.clock)
    #expect(second.clock.wallMillis == first.clock.wallMillis + 60_000)
  }
}
