import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let aYear: TimeInterval = 365 * 86_400

private struct Prepared {
  let store: VaultStore
  let reconciler: RecordingReconciler
  let pending: [ChangeRecord]
}

private func prepare(_ generator: inout SeededGenerator, clock: ManualClock = ManualClock()) async throws -> Prepared {
  let reconciler = RecordingReconciler()
  let store = try VaultStore.open(.inMemory, registry: Fixture.v2, wallClock: clock.function, reconciler: reconciler)
  var factory = ChangeFactory()
  var known = [EntityRef: [String]]()
  var local = [ChangeRecord]()
  for _ in 0..<generator.int(in: 1...4) {
    let result = try await runLocal((0..<generator.int(in: 1...10)).map { _ in LocalOperation.random(&generator) }, in: store, known: known)
    local += result.records
    known = result.known
    _ = try await store.applyRemote(Remote.lines(factory.changes(&generator, count: 0...6), &generator))
  }
  let dropped = generator.int(in: 0...local.count)
  try await store.dropChanges(through: Int64(dropped))
  reconciler.clear()
  return Prepared(store: store, reconciler: reconciler, pending: Array(local.dropFirst(dropped)))
}

@Suite("VaultStore re-mint retention and reconciliation")
struct StoreRemintRetentionTests {
  @Test("should leave both scopes equal to the retained reference of the re-created records and reset then reconcile exactly their refs")
  func shouldPruneAndReconcileRebuild() async throws {
    try await forAll(iterations: 100, seed: 0x4E_B11D) { generator in
      let clock = ManualClock(ManualClock.start.addingTimeInterval(aYear))
      let prepared = try await prepare(&generator, clock: clock)
      clock.set(ManualClock.start)
      try await prepared.store.remint(to: ReplicaID(UUID.v7()), mode: .rebuild)
      let rebuilt = try await prepared.store.allPending.map { try Stored.record($0.line) }
      try #require(rebuilt.count == prepared.pending.count)
      let expected = Remote.reference(rebuilt, Fixture.v2)
      try #require(try await prepared.store.loadState(.vault) == expected)
      try #require(try await prepared.store.loadState(.own) == expected)
      let refs = Set(rebuilt.map(\.ref)).sorted()
      let reconciled = refs.isEmpty ? [] : [ReconcilerEvent.reconcile(ReconcilerCall(touched: refs, origin: .local, revisionRows: expected.revisionCount))]
      try #require(prepared.reconciler.events == [.reset] + reconciled)
    }
  }

  @Test("should leave the own scope equal to the retained reference of the pending records without calling the reconciler when keeping state")
  func shouldPruneKeptState() async throws {
    try await forAll(iterations: 100, seed: 0x4E_C0) { generator in
      let prepared = try await prepare(&generator)
      let vault = try await prepared.store.loadState(.vault)
      try await prepared.store.remint(to: ReplicaID(UUID.v7()), mode: .keepState)
      try #require(try await prepared.store.loadState(.own) == Remote.reference(prepared.pending, Fixture.v2))
      try #require(try await prepared.store.loadState(.vault) == vault)
      try #require(prepared.reconciler.events.isEmpty)
    }
  }

  @Test("should leave the store exactly as it was, replica included, when the reset or the reconcile throws", arguments: [false, true])
  func shouldRollBackFailingReconciler(_ failingReset: Bool) async throws {
    var generator = SeededGenerator(seed: 0xFA11)
    let prepared = try await prepare(&generator)
    try #require(!prepared.pending.isEmpty)
    let before = try await StoreImage(prepared.store)
    let replica = prepared.store.replica
    let store = prepared.store
    if failingReset { prepared.reconciler.failReset(true) } else { prepared.reconciler.fail(true) }
    let error = await #expect(throws: StoreError.self) { try await store.remint(to: ReplicaID(UUID.v7()), mode: .rebuild) }
    guard case .reconcilerFailed(let underlying) = error else { throw StoreTestFailure.unexpectedState }
    #expect(underlying is ReconcilerFailure)
    #expect(store.replica == replica)
    #expect(try await StoreImage(store) == before)
  }
}

extension VaultState {
  fileprivate var revisionCount: Int {
    refs.reduce(0) { count, ref in
      guard case .revisioned(let state) = state(of: ref) else { return count }
      return count + state.revisions.count
    }
  }
}
