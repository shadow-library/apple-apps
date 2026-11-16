import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let notes = ["k3", "k1", "k2"].map { EntityRef(kind: Fixture.note, key: Fixture.key($0)) }
private let outline = EntityRef(kind: Fixture.outline, key: Fixture.key("d1"))

private func open(_ reconciler: RecordingReconciler, _ registry: SchemaRegistry = Fixture.v2, at location: StoreLocation = .inMemory) throws -> VaultStore {
  try VaultStore.open(location, registry: registry, wallClock: ManualClock().function, reconciler: reconciler)
}

@Suite("VaultStore reconciler")
struct StoreReconcilerTests {
  @Test("should be called once per local write with the touched refs sorted and de-duplicated")
  func shouldReconcileLocalWrites() async throws {
    let reconciler = RecordingReconciler()
    let store = try open(reconciler)
    _ = try await store.write { transaction in
      for ref in notes + notes { _ = try transaction.set(ref, ["title": "t"]) }
      _ = try transaction.revise(outline, body: "one")
    }
    #expect(reconciler.calls.map(\.touched) == [[notes[1], notes[2], notes[0], outline].sorted()])
    #expect(reconciler.calls.map(\.origin) == [.local])
  }

  @Test("should be called once per remote apply with the refs whose declared part was merged")
  func shouldReconcileRemoteApplies() async throws {
    try await forAll(iterations: 100, seed: 0x4EC0) { generator in
      let reconciler = RecordingReconciler()
      let store = try open(reconciler, Fixture.v1)
      var factory = ChangeFactory()
      let records = factory.changes(&generator, count: 1...20)
      let result = try await store.applyRemote(Remote.lines(records, &generator))
      let touched = Remote.touched(records, Fixture.v1)
      try #require(result.touched == touched)
      try #require(reconciler.calls.map(\.touched) == (touched.isEmpty ? [] : [touched]))
      try #require(reconciler.calls.allSatisfy { $0.origin == .remote })
    }
  }

  @Test("should see the state after retention on both paths")
  func shouldSeeRetainedState() async throws {
    let reconciler = RecordingReconciler()
    let store = try open(reconciler)
    let items = (0...4).map { RevisionItem(parent: nil, body: .int(Int64($0)), created: Fixture.clock(Int64($0), replica: 1), generation: Int64($0)) }
    _ = try await store.applyRemote(items.map { Fixture.revise($0, clock: $0.created, entity: outline.kind, key: outline.key, head: false).canonicalBytes() })
    _ = try await store.write { transaction in try transaction.revise(outline, body: "local") }
    #expect(reconciler.calls.map(\.revisionRows) == [1, 1])
    #expect(reconciler.calls.map(\.origin) == [.remote, .local])
  }

  @Test("should not be called for a transaction that touched nothing")
  func shouldSkipUntouchedTransactions() async throws {
    let reconciler = RecordingReconciler()
    let directory = TemporaryDirectory()
    let store = try open(reconciler, Fixture.v1, at: .file(directory.storeURL))
    try await store.write { transaction in try transaction.database.execute(sql: "SELECT 1") }
    _ = try await store.applyRemote([Data("opaque".utf8)])
    _ = try await store.applyRemote([Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(1, replica: 1), fields: ["label": "x"]).canonicalBytes()])
    _ = try open(reconciler, Fixture.v1, at: .file(directory.storeURL))
    #expect(reconciler.calls.isEmpty)
  }

  @Test("should roll back the whole local write when the reconciler throws")
  func shouldRollBackLocalWrite() async throws {
    let reconciler = RecordingReconciler()
    let store = try open(reconciler)
    _ = try await store.write { transaction in try transaction.set(notes[0], ["title": "kept"]) }
    let before = try await StoreImage(store)
    reconciler.fail(true)
    let error = await #expect(throws: StoreError.self) {
      try await store.write { transaction in
        _ = try transaction.set(notes[1], ["title": "lost"])
        _ = try transaction.revise(outline, body: "lost")
      }
    }
    guard case .reconcilerFailed(let underlying) = error else { throw StoreTestFailure.unexpectedState }
    #expect(underlying is ReconcilerFailure)
    #expect(try await StoreImage(store) == before)
    reconciler.fail(false)
    let next = try await store.write { transaction in try transaction.set(notes[1], ["title": "next"]) }
    #expect(try await store.allPending.last == LoggedChange(sequence: 2, line: next.canonicalBytes()))
  }
}
