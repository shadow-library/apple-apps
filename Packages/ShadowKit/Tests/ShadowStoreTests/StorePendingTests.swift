import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))

private func writeNotes(_ count: Int, _ generator: inout SeededGenerator, to store: VaultStore) async throws {
  let titles = (0..<count).map { _ in JSONValue.string(String(repeating: "x", count: generator.int(in: 0...200))) }
  _ = try await store.write { transaction in
    for title in titles { _ = try transaction.set(note, ["title": title]) }
  }
}

@Suite("VaultStore bounded pending changes")
struct StorePendingTests {
  @Test("should return a maximal prefix in sequence order within the budget and the limit")
  func shouldReturnAMaximalPrefix() async throws {
    try await forAll(iterations: 100, seed: 0x9E_0001) { generator in
      let store = try StoreFixture.open(Fixture.v1)
      try await writeNotes(generator.int(in: 1...15), &generator, to: store)
      let all = try await store.allPending
      let limit = generator.int(in: -1...(all.count + 2))
      let budget = generator.int(in: 0...(all.map(\.line.count).reduce(0, +) + 50))
      let result = try await store.pendingChanges(limit: limit, maximumBytes: budget)
      let size = result.map(\.line.count).reduce(0, +)
      try #require(result == Array(all.prefix(result.count)))
      try #require(result.count <= max(limit, 0))
      try #require(size <= budget || result.count == 1)
      try #require(result.count == min(max(limit, 0), all.count) || result.count == 0 && limit <= 0 || size + all[result.count].line.count > budget)
      if limit > 0 { try #require(!result.isEmpty) }
    }
  }

  @Test("should return the first change alone when it is larger than the budget, a zero budget or a negative budget")
  func shouldReturnTheFirstChangeAlone() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    _ = try await store.write { transaction in
      _ = try transaction.set(note, ["title": "first"])
      return try transaction.set(note, ["title": "second"])
    }
    let all = try await store.allPending
    for budget in [1, 0, -1, Int.min] { #expect(try await store.pendingChanges(limit: 10, maximumBytes: budget) == [all[0]]) }
  }

  @Test("should include a change that exactly fills the budget and stop before the one that crosses it")
  func shouldStopBeforeTheChangeThatCrosses() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    _ = try await store.write { transaction in
      for title in ["a", "b", "c"] { _ = try transaction.set(note, ["title": .string(title)]) }
    }
    let all = try await store.allPending
    let two = all[0].line.count + all[1].line.count
    #expect(try await store.pendingChanges(limit: 10, maximumBytes: two) == Array(all.prefix(2)))
    #expect(try await store.pendingChanges(limit: 10, maximumBytes: two - 1) == [all[0]])
  }

  @Test("should return nothing for a non-positive limit or an empty log")
  func shouldReturnNothing() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    #expect(try await store.pendingChanges(limit: 5, maximumBytes: 100).isEmpty)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "a"]) }
    for limit in [0, -1, Int.min] { #expect(try await store.pendingChanges(limit: limit, maximumBytes: 100).isEmpty) }
  }

  @Test("should equal the count-limited read when the budget is large")
  func shouldEqualTheCountLimitedRead() async throws {
    try await forAll(iterations: 50, seed: 0x9E_0002) { generator in
      let store = try StoreFixture.open(Fixture.v1)
      try await writeNotes(generator.int(in: 0...12), &generator, to: store)
      let limit = generator.int(in: 0...15)
      try #require(try await store.pendingChanges(limit: limit, maximumBytes: .max) == store.pendingChanges(limit: limit))
    }
  }

  @Test("should list the clocks of the unsent changes in sequence order")
  func shouldListClocks() async throws {
    try await forAll(iterations: 50, seed: 0x9E_0003) { generator in
      let store = try StoreFixture.open(Fixture.v1)
      var known = [EntityRef: [String]]()
      let result = try await runLocalLeniently((0..<generator.int(in: 0...10)).map { _ in LocalOperation.random(&generator) }, in: store, known: known)
      known = result.known
      try #require(try await store.pendingClocks() == result.records.map(\.clock))
      let decoded = try await store.pendingChanges(limit: .max).map { try Stored.record($0.line).clock }
      try #require(try await store.pendingClocks() == decoded)
      let dropped = generator.int(in: 0...result.records.count)
      try await store.dropChanges(through: Int64(dropped))
      try #require(try await store.pendingClocks() == result.records.dropFirst(dropped).map(\.clock))
    }
  }

  @Test("should list no clocks for an empty log and refuse a line that does not decode")
  func shouldRefuseCorruptLines() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    #expect(try await store.pendingClocks().isEmpty)
    _ = try await store.write { transaction in
      try transaction.database.execute(sql: "INSERT INTO change_log (seq, line) VALUES (1, X'7B')")
    }
    let error = await #expect(throws: StoreError.self) { try await store.pendingClocks() }
    #expect(error?.code == "store.corrupt_store")
  }

  @Test("should start the sequence after the base position and advance it by one per committed change in the same transaction")
  func shouldAdvanceTheNextSequence() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    let first = try await store.write { try $0.nextSequence }
    #expect(first == 1)
    let observed = try await store.write { transaction in
      var sequences = [try transaction.nextSequence]
      _ = try transaction.set(note, ["title": "a"])
      sequences.append(try transaction.nextSequence)
      _ = try transaction.append(EntityRef(kind: Fixture.message, key: Fixture.key("m1")), item: ["text": "b"])
      sequences.append(try transaction.nextSequence)
      return sequences
    }
    #expect(observed == [1, 2, 3])
    #expect(try await store.write { try $0.nextSequence } == (try await store.ownSnapshot().upTo) + 1)
  }

  @Test("should not consume a number when an operation throws, including one rolled back after the number was taken")
  func shouldNotConsumeOnFailure() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "a"]) }
    let (before, afterRefusal, afterRollback) = try await store.write { transaction in
      let before = try transaction.nextSequence
      do { _ = try transaction.set(note, [:]) } catch StoreError.invalidChange {}
      let afterRefusal = try transaction.nextSequence
      try transaction.database.execute(sql: "INSERT INTO change_log (seq, line) VALUES (?, X'7B')", arguments: [before])
      do { _ = try transaction.set(note, ["title": "b"]) } catch StoreError.database {}
      return (before, afterRefusal, try transaction.nextSequence)
    }
    #expect(before == 2)
    #expect(afterRefusal == before)
    #expect(afterRollback == before)
  }

  @Test("should not consume a number when the whole transaction throws")
  func shouldNotConsumeWhenTheTransactionThrows() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in
        _ = try transaction.set(note, ["title": "a"])
        _ = try transaction.set(note, [:])
      }
    }
    #expect(try await store.write { try $0.nextSequence } == 1)
  }
}
