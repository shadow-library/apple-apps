import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))

@Suite("VaultStore public clock floor")
struct StorePublicClockFloorTests {
  @Test("should be nil for a fresh store")
  func shouldBeNilWhenFresh() async throws {
    #expect(try await StoreFixture.open().publicClockFloor() == nil)
  }

  @Test("should equal the acknowledged clock after a drop and the higher of the two after a remote apply")
  func shouldFollowAcknowledgedAndObserved() async throws {
    let clock = ManualClock()
    let store = try StoreFixture.open(clock: clock)
    let written = try await store.write { transaction in try (1...2).map { try transaction.set(note, ["title": .int(Int64($0))]) } }
    #expect(try await store.publicClockFloor() == nil)
    try await store.dropChanges(through: 1)
    #expect(try await store.publicClockFloor() == written[0].clock)
    let low = Fixture.change(.set, note.kind, note.key, clock: must(HLCTimestamp(wallMillis: 1, counter: 0, replica: Fixture.replicas[1]), "low"), fields: ["title": "low"])
    _ = try await store.applyRemote([low.canonicalBytes()])
    #expect(try await store.publicClockFloor() == written[0].clock)
    let high = must(HLCTimestamp(wallMillis: clock.millis + 3_600_000, counter: 2, replica: Fixture.replicas[2]), "high")
    _ = try await store.applyRemote([Fixture.change(.set, note.kind, note.key, clock: high, fields: ["title": "high"]).canonicalBytes()])
    #expect(try await store.publicClockFloor() == high)
  }

  @Test("should be unchanged by either re-mint", arguments: [RemintMode.keepState, .rebuild])
  func shouldSurviveRemint(_ mode: RemintMode) async throws {
    let store = try StoreFixture.open()
    _ = try await store.write { transaction in try (1...3).map { try transaction.set(note, ["title": .int(Int64($0))]) } }
    try await store.dropChanges(through: 2)
    _ = try await store.applyRemote([Fixture.change(.set, Fixture.note, Fixture.key("k2"), clock: Fixture.clock(1, replica: 1), fields: ["title": "r"]).canonicalBytes()])
    let floor = try #require(try await store.publicClockFloor())
    try await store.remint(to: ReplicaID(UUID.v7()), mode: mode)
    #expect(try await store.publicClockFloor() == floor)
  }

  @Test("should never decrease over random writes, drops and remote applies")
  func shouldNeverDecrease() async throws {
    try await forAll(iterations: 100, seed: 0xF100_4) { generator in
      let store = try StoreFixture.open(Fixture.v2)
      var factory = ChangeFactory()
      var known = [EntityRef: [String]]()
      var written = Int64(0)
      var floor: HLCTimestamp?
      for _ in 0..<generator.int(in: 1...10) {
        switch generator.int(in: 0...2) {
        case 0:
          let result = try await runLocal((0..<generator.int(in: 1...4)).map { _ in LocalOperation.random(&generator) }, in: store, known: known)
          written += Int64(result.records.count)
          known = result.known
        case 1:
          try await store.dropChanges(through: Int64(generator.int(in: 0...Int(written))))
        default:
          _ = try await store.applyRemote(Remote.lines(factory.changes(&generator, count: 0...6), &generator))
        }
        let next = try await store.publicClockFloor()
        if let floor { try #require(next.map { $0 >= floor } == true) }
        floor = next
      }
    }
  }
}
