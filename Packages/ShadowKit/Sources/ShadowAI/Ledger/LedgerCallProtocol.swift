import CryptoKit
import Foundation
import ShadowStore

extension Ledger {
  /// Protocol: `begin` before the request leaves, `finish` after the stream ends, each in its own short transaction.
  public static func begin(_ call: ModelCallStart, in transaction: inout WriteTransaction) throws(StoreError) {
    try open(entry(of: call, id: call.id, parent: nil, outcome: .started, usage: .zero, ids: nil, priced: (nil, .pending)), in: &transaction)
  }

  /// Every device must pass the same event list for a call, since only the device that made the request has it; attempts are numbered in that list's order.
  public static func finish(
    _ call: ModelCallStart, events: [ModelEvent], endedWith error: ModelError?, catalog: ModelCatalog?, in transaction: inout WriteTransaction
  ) throws(StoreError) -> [ModelCallEntry] {
    let begunRef = ref(call.id)
    guard let state = try transaction.state(of: begunRef), let begun = entry(ref: begunRef, state: state) else {
      throw .invalidChange("model call \(begunRef.key) is not recorded")
    }
    guard begun.outcome != .finished else { return try storedEntries(of: call, in: transaction) }
    let attempts = ModelCallAccounting.attempts(from: events, endedWith: error)
    guard let last = attempts.last else {
      try close(id: call.id, outcome: .failed, usage: .zero, cost: nil, source: .pending, in: &transaction)
      return try storedEntries(of: call, in: transaction)
    }
    let closing = ModelCallAccounting.cost(for: last, model: call.model, catalog: catalog)
    try identify(id: call.id, requestID: last.requestID, generationID: last.generationID, in: &transaction)
    try close(id: call.id, outcome: last.outcome, usage: last.usage, cost: closing.cost, source: closing.source, in: &transaction)
    for (index, abandoned) in attempts.dropLast().enumerated() {
      let priced = ModelCallAccounting.cost(for: abandoned, model: call.model, catalog: catalog)
      try open(try entry(of: call, id: attemptID(of: call.id, index: index), parent: call.id, attempt: abandoned, priced: priced), in: &transaction)
    }
    return try storedEntries(of: call, in: transaction)
  }

  static func attemptID(of call: UUID, index: Int) -> UUID {
    var bytes = Array(SHA256.hash(data: Data("shadow.ai.call-attempt:\(EntityKey(uuid: call).rawValue):\(index)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x80
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
  }

  private static func storedEntries(of call: ModelCallStart, in transaction: borrowing WriteTransaction) throws(StoreError) -> [ModelCallEntry] {
    var written: [ModelCallEntry] = []
    var id = call.id
    while true {
      let entryRef = ref(id)
      guard let state = try transaction.state(of: entryRef), let stored = entry(ref: entryRef, state: state) else { break }
      written.append(stored)
      id = attemptID(of: call.id, index: written.count - 1)
    }
    return written
  }

  private static func entry(
    of call: ModelCallStart, id: UUID, parent: UUID?, attempt: ModelCallAttempt, priced: (cost: Cost?, source: LedgerCostSource)
  ) throws(StoreError) -> ModelCallEntry {
    try entry(of: call, id: id, parent: parent, outcome: attempt.outcome, usage: attempt.usage, ids: (attempt.requestID, attempt.generationID), priced: priced)
  }

  private static func entry(
    of call: ModelCallStart, id: UUID, parent: UUID?, outcome: LedgerOutcome, usage: TokenUsage, ids: (request: String?, generation: String?)?,
    priced: (cost: Cost?, source: LedgerCostSource)
  ) throws(StoreError) -> ModelCallEntry {
    ModelCallEntry(
      id: id, provider: try LedgerProvider.normalised(call.provider), model: call.model, task: call.task, pace: call.pace, startedMillis: call.startedMillis, parent: parent,
      requestID: ids?.request, generationID: ids?.generation, outcome: outcome, usage: usage, cost: priced.cost, costSource: priced.source)
  }
}
