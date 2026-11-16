import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Synchronization

@testable import ShadowStore

struct ReconcilerCall: Sendable, Equatable {
  let touched: [EntityRef]
  let origin: ChangeOrigin
  let revisionRows: Int
}

struct ReconcilerFailure: Error {}

enum ReconcilerEvent: Sendable, Equatable {
  case reset
  case reconcile(ReconcilerCall)
}

final class RecordingReconciler: StoreReconciler {
  private struct State {
    var events: [ReconcilerEvent] = []
    var failing = false
    var failingReset = false
  }

  private let state = Mutex(State())

  init(failing: Bool = false, failingReset: Bool = false) {
    state.withLock { state in
      state.failing = failing
      state.failingReset = failingReset
    }
  }

  var events: [ReconcilerEvent] {
    state.withLock { $0.events }
  }

  var calls: [ReconcilerCall] {
    events.compactMap { event in
      guard case .reconcile(let call) = event else { return nil }
      return call
    }
  }

  func fail(_ failing: Bool) {
    state.withLock { $0.failing = failing }
  }

  func failReset(_ failing: Bool) {
    state.withLock { $0.failingReset = failing }
  }

  func clear() {
    state.withLock { $0.events = [] }
  }

  func reconcile(_ touched: [EntityRef], origin: ChangeOrigin, in database: Database) throws {
    let rows = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM revision WHERE scope = 0") ?? -1
    let failing = state.withLock { state in
      state.events.append(.reconcile(ReconcilerCall(touched: touched, origin: origin, revisionRows: rows)))
      return state.failing
    }
    if failing { throw ReconcilerFailure() }
  }

  func reset(in database: Database) throws {
    let failing = state.withLock { state in
      state.events.append(.reset)
      return state.failingReset
    }
    if failing { throw ReconcilerFailure() }
  }
}

struct StoreImage: Equatable {
  let vault: String
  let own: String
  let pending: [LoggedChange]
  let kernel: [String]

  init(_ store: VaultStore) async throws {
    vault = try await store.loadState(.vault).digest
    own = try await store.loadState(.own).digest
    pending = try await store.allPending
    kernel = try await store.read { transaction in
      try Row.fetchOne(transaction.database, sql: "SELECT * FROM kernel_state").map { row in row.databaseValues.map(\.description) } ?? []
    }
  }
}

enum Remote {
  static func lines(_ records: [ChangeRecord], opaque: [Data] = [], _ generator: inout SeededGenerator) -> [Data] {
    generator.shuffled(generator.withDuplicates(records).map { $0.canonicalBytes() } + opaque + opaque.prefix(1))
  }

  static func touched(_ records: [ChangeRecord], _ registry: SchemaRegistry) -> [EntityRef] {
    Set(records.filter { registry.interpretation(of: $0).state != nil }.map(\.ref)).sorted()
  }

  static func reference(_ records: [ChangeRecord], opaque: [Data] = [], _ registry: SchemaRegistry) -> VaultState {
    var state = Fixture.state(records, registry)
    for line in opaque { state.keepOpaque(line) }
    return state.retained(registry: registry)
  }
}

/// Runs the operations, skipping any the registry refuses, so a script written for a newer registry also runs under an older one.
func runLocalLeniently(_ operations: [LocalOperation], in store: VaultStore, known: [EntityRef: [String]]) async throws -> (
  records: [ChangeRecord], known: [EntityRef: [String]]
) {
  try await store.write { transaction in
    var known = known
    var records = [ChangeRecord]()
    for operation in operations {
      do {
        if let record = try operation.run(&transaction, known: &known) { records.append(record) }
      } catch StoreError.invalidChange {
        continue
      }
    }
    return (records, known)
  }
}
