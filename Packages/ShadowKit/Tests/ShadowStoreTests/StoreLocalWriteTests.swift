import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let draft = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))

@Suite("VaultStore local writes")
struct StoreLocalWriteTests {
  @Test("should keep both scopes equal to the reference of the returned records and log them in order")
  func shouldMatchReferenceOfLocalWrites() async throws {
    try await forAll(iterations: 200) { generator in
      let store = try StoreFixture.open(Fixture.v2)
      var known = [EntityRef: [String]]()
      var records = [ChangeRecord]()
      for _ in 0..<generator.int(in: 1...4) {
        let operations = (0..<generator.int(in: 1...15)).map { _ in LocalOperation.random(&generator) }
        let result = try await runLocal(operations, in: store, known: known)
        records += result.records
        known = result.known
      }
      let expected = Fixture.state(records, Fixture.v2).retained(registry: Fixture.v2)
      try #require(try await store.loadState(.vault) == expected)
      try #require(try await store.loadState(.vault).digest == expected.digest)
      try #require(try await store.loadState(.own).digest == expected.digest)
      try #require(try await store.allPending == StoreFixture.logged(records))
      try #require(records.allSatisfy { $0.schema == Fixture.v2.version && $0.clock.replica == store.replica })
    }
  }

  @Test("should return the transaction's changes in the order written")
  func shouldExposeTransactionChanges() async throws {
    let store = try StoreFixture.open()
    let (returned, listed) = try await store.write { transaction in
      let first = try transaction.set(note, ["title": "a"])
      let (second, _) = try transaction.revise(draft, body: "body")
      let third = try transaction.purge(note)
      return ([first, second, third], transaction.changes)
    }
    #expect(returned == listed)
    #expect(try await store.allPending == StoreFixture.logged(returned))
  }

  @Test("should derive revisions from the vault scope's head and next generation and re-assert them unchanged")
  func shouldBuildRevisions() async throws {
    let clock = ManualClock()
    let store = try StoreFixture.open(clock: clock)
    let (first, firstID) = try await store.write { transaction in try transaction.revise(draft, body: "one") }
    let (second, secondID) = try await store.write { transaction in try transaction.revise(draft, body: "two", marks: ["approved"]) }
    let (orphan, orphanID) = try await store.write { transaction in try transaction.revise(draft, body: "three", parent: .none, head: false) }
    let (branch, _) = try await store.write { transaction in try transaction.revise(draft, body: "four", parent: .revision(firstID), head: false) }
    let reassert = try await store.write { transaction in try transaction.reassert(draft, revision: orphanID, head: true) }
    #expect(first.fields["parent"] == .null && first.fields["generation"] == 0 && first.fields["created"] == .string(first.clock.description))
    #expect(second.fields["parent"] == .string(firstID) && second.fields["generation"] == 1 && second.fields["marks"] == ["approved"])
    #expect(orphan.fields["parent"] == .null && orphan.fields["generation"] == 2 && orphan.fields["head"] == false)
    #expect(branch.fields["parent"] == .string(firstID) && branch.fields["generation"] == 3)
    #expect(reassert.fields["revision"] == .string(orphanID) && reassert.fields["created"] == orphan.fields["created"] && reassert.clock > orphan.clock)
    guard case .revisioned(let state) = try await store.read({ try $0.state(of: draft) }) else { throw StoreTestFailure.unexpectedState }
    #expect(state.headRevision == orphanID)
    #expect(state[mark: "approved"]?.value == .string(secondID))
    #expect(state.revisions.count == 3 && state.revisions[ExactString(firstID)] == nil)
  }

  @Test("should drop a prefix of the log without ever reusing a sequence number")
  func shouldDropPrefixes() async throws {
    try await forAll(iterations: 100) { generator in
      let store = try StoreFixture.open(Fixture.v2)
      var logged = [LoggedChange]()
      var next: Int64 = 1
      for _ in 0..<generator.int(in: 1...5) {
        let operations = (0..<generator.int(in: 0...8)).map { _ in LocalOperation.random(&generator) }
        let records = try await runLocal(operations, in: store, known: [:]).records
        logged += StoreFixture.logged(records, from: next)
        next += Int64(records.count)
        try #require(try await store.allPending == logged)
        let through = generator.chance(0.5) ? Int64(generator.int(in: 0...Int(next))) : next - 1
        try await store.dropChanges(through: through)
        logged.removeAll { $0.sequence <= through }
        try #require(try await store.allPending == logged)
      }
      let limit = generator.int(in: 0...3)
      try #require(try await store.pendingChanges(limit: limit) == Array(logged.prefix(limit)))
    }
  }

  @Test("should keep the vault scope equal to the reference of all records and the own scope to the local ones")
  func shouldSeparateLocalFromRemote() async throws {
    try await forAll(iterations: 200) { generator in
      let store = try StoreFixture.open(Fixture.v2)
      var factory = ChangeFactory()
      var known = [EntityRef: [String]]()
      var local = [ChangeRecord]()
      var remote = [ChangeRecord]()
      for _ in 0..<generator.int(in: 1...6) {
        if generator.chance(0.5) {
          let records = factory.changes(&generator, count: 0...8)
          try await store.apply(records)
          remote += records
        } else {
          let result = try await runLocal((0..<generator.int(in: 1...8)).map { _ in LocalOperation.random(&generator) }, in: store, known: known)
          local += result.records
          known = result.known
        }
      }
      try #require(try await store.loadState(.vault).digest == Fixture.state(local + remote, Fixture.v2).retained(registry: Fixture.v2).digest)
      try #require(try await store.loadState(.own).digest == Fixture.state(local, Fixture.v2).retained(registry: Fixture.v2).digest)
      try #require(try await store.allPending == StoreFixture.logged(local))
    }
  }
}

enum StoreTestFailure: Error {
  case unexpectedState
}
