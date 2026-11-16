import Foundation
import ShadowCore
import ShadowStore
import Synchronization

@testable import ShadowAI

final class LedgerTestClock: Sendable {
  static let start = Date(timeIntervalSince1970: 1_700_000_000)

  private let date = Mutex(LedgerTestClock.start)

  var now: Date { date.withLock { $0 } }

  var millis: Int64 { Int64(now.timeIntervalSince1970 * 1_000) }

  var function: @Sendable () -> Date { { self.now } }

  func advance(by seconds: TimeInterval = 1) {
    date.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

enum LedgerFixture {
  static let host = "api.example.com"

  static let noteKind: EntityKind = {
    guard let kind = EntityKind("app_note") else { preconditionFailure("valid kind") }
    return kind
  }()

  static let registry = SchemaRegistry(
    version: 1,
    entities: LedgerSchema.entities + [EntitySchema(kind: noteKind, shape: .record(fields: ["title": .register]), syncClass: .general)]
  )

  static func store(_ clock: LedgerTestClock = LedgerTestClock()) throws -> VaultStore {
    try VaultStore.open(.inMemory, registry: registry, wallClock: clock.function)
  }

  static func entry(
    id: UUID = UUID(),
    provider: String = host,
    model: String = "model-a",
    task: ModelTask = .writing,
    pace: Pace? = .steady,
    startedMillis: Int64 = 1_700_000_000_000,
    parent: UUID? = nil,
    requestID: String? = "req_1",
    generationID: String? = nil,
    outcome: LedgerOutcome = .started,
    usage: TokenUsage = .zero,
    cost: Cost? = nil,
    costSource: LedgerCostSource = .pending
  ) -> ModelCallEntry {
    ModelCallEntry(
      id: id, provider: provider, model: model, task: task, pace: pace, startedMillis: startedMillis, parent: parent, requestID: requestID, generationID: generationID,
      outcome: outcome,
      usage: usage, cost: cost, costSource: costSource)
  }

  static func open(_ call: ModelCallEntry, in store: VaultStore) async throws {
    try await store.write { transaction in try Ledger.open(call, in: &transaction) }
  }

  static func close(
    _ id: UUID, _ outcome: LedgerOutcome, usage: TokenUsage = .zero, cost: Cost? = nil, source: LedgerCostSource = .pending, in store: VaultStore
  ) async throws {
    try await store.write { transaction in try Ledger.close(id: id, outcome: outcome, usage: usage, cost: cost, source: source, in: &transaction) }
  }

  static func identify(_ id: UUID, request: String?, generation: String?, in store: VaultStore) async throws {
    try await store.write { transaction in try Ledger.identify(id: id, requestID: request, generationID: generation, in: &transaction) }
  }

  static func reconcile(_ id: UUID, _ cost: Cost, in store: VaultStore) async throws {
    try await store.write { transaction in try Ledger.reconcile(id: id, cost: cost, in: &transaction) }
  }

  static func entries(_ store: VaultStore) async throws -> [ModelCallEntry] {
    try await store.read { transaction in try Ledger.entries(in: transaction) }
  }

  static func exchange(_ first: VaultStore, _ second: VaultStore) async throws {
    let fromFirst = try await first.pendingChanges(limit: Int.max).map(\.line)
    let fromSecond = try await second.pendingChanges(limit: Int.max).map(\.line)
    _ = try await second.applyRemote(fromFirst)
    _ = try await first.applyRemote(fromSecond)
  }
}
