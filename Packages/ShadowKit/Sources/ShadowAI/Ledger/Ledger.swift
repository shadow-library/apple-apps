import Foundation
import ShadowCore
import ShadowStore

public enum Ledger {
  public static func open(_ call: ModelCallEntry, in transaction: inout WriteTransaction) throws(StoreError) {
    let facts: JSONValue = .object([
      LedgerCallKey.provider: .string(try LedgerProvider.normalised(call.provider)),
      LedgerCallKey.model: .string(call.model),
      LedgerCallKey.task: .string(call.task.rawValue),
      LedgerCallKey.pace: call.pace.map { .string($0.rawValue) } ?? .null,
      LedgerCallKey.started: .int(call.startedMillis),
      LedgerCallKey.parent: call.parent.map { .string(EntityKey(uuid: $0).rawValue) } ?? .null,
    ])
    var fields = settled(outcome: call.outcome, usage: call.usage, cost: call.cost, source: call.costSource)
    fields[LedgerField.call] = facts
    if let requestID = call.requestID { fields[LedgerField.requestID] = .string(requestID) }
    if let generationID = call.generationID { fields[LedgerField.generationID] = .string(generationID) }
    try write(fields, to: ref(call.id), in: &transaction)
  }

  public static func close(
    id: UUID, outcome: LedgerOutcome, usage: TokenUsage, cost: Cost?, source: LedgerCostSource, in transaction: inout WriteTransaction
  ) throws(StoreError) {
    let ref = ref(id)
    try requireRecorded(ref, in: transaction)
    try write(settled(outcome: outcome, usage: usage, cost: cost, source: source), to: ref, in: &transaction)
  }

  public static func identify(id: UUID, requestID: String?, generationID: String?, in transaction: inout WriteTransaction) throws(StoreError) {
    let ref = ref(id)
    guard case .record(let record)? = try transaction.state(of: ref) else { throw .invalidChange("model call \(ref.key) is not recorded") }
    var fields: [String: JSONValue] = [:]
    if let requestID, record[field: LedgerField.requestID] == nil { fields[LedgerField.requestID] = .string(requestID) }
    if let generationID, record[field: LedgerField.generationID] == nil { fields[LedgerField.generationID] = .string(generationID) }
    guard !fields.isEmpty else { return }
    try write(fields, to: ref, in: &transaction)
  }

  /// `cost_reported` is first-writer-wins so a repeated reconcile cannot flip or double a number; the first write must be the provider's final figure.
  public static func reconcile(id: UUID, cost: Cost, in transaction: inout WriteTransaction) throws(StoreError) {
    let ref = ref(id)
    try requireRecorded(ref, in: transaction)
    try write([LedgerField.costReported: .int(cost.nanoUSD)], to: ref, in: &transaction)
  }

  /// A begun call that never finished may have been billed: leave it pending unless the provider confirms, because closing it as failed without a generation id makes it read as zero cost.
  public static func unfinished(in transaction: ReadTransaction, olderThanMillis: Int64) throws(StoreError) -> [ModelCallEntry] {
    try entries(in: transaction).filter { $0.outcome == .started && $0.startedMillis < olderThanMillis }
  }

  public static func entries(in transaction: ReadTransaction) throws(StoreError) -> [ModelCallEntry] {
    try transaction.states(ofKind: LedgerSchema.modelCallKind)
      .compactMap { entry(ref: $0.ref, state: $0.state) }
      .sorted { ($0.startedMillis, $0.id.uuidString) < ($1.startedMillis, $1.id.uuidString) }
  }

  private struct Malformed: Error {}

  static func entry(ref: EntityRef, state: EntityState) -> ModelCallEntry? {
    try? decode(ref, state)
  }

  static func ref(_ id: UUID) -> EntityRef {
    EntityRef(kind: LedgerSchema.modelCallKind, key: EntityKey(uuid: id))
  }

  private static func write(_ fields: [String: JSONValue], to ref: EntityRef, in transaction: inout WriteTransaction) throws(StoreError) {
    var stored: RecordState?
    if case .record(let record)? = try transaction.state(of: ref) { stored = record }
    let changed = fields.filter { !isCovered($0.key, $0.value, by: stored) }
    guard !changed.isEmpty else { return }
    _ = try transaction.set(ref, changed)
  }

  private static func isCovered(_ name: String, _ value: JSONValue, by stored: RecordState?) -> Bool {
    guard let current = stored?[field: name] else { return false }
    switch current.rule {
    case .firstWriterWins: return true
    case .register: return current.value == value
    case .monotone(let order):
      guard let next = value.stringValue.flatMap(order.firstIndex(of:)), let existing = current.value.stringValue.flatMap(order.firstIndex(of:)) else { return false }
      return next <= existing
    }
  }

  private static func requireRecorded(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(StoreError) {
    guard case .record? = try transaction.state(of: ref) else { throw .invalidChange("model call \(ref.key) is not recorded") }
  }

  /// A computed cost is written only by a finished close, so a later failed or cancelled close cannot replace it; zero usage is left unwritten for the same reason.
  private static func settled(outcome: LedgerOutcome, usage: TokenUsage, cost: Cost?, source: LedgerCostSource) -> [String: JSONValue] {
    var fields: [String: JSONValue] = [LedgerField.outcome: .string(outcome.rawValue)]
    if usage != .zero { fields[LedgerField.usage] = encode(usage) }
    guard let cost else { return fields }
    switch source {
    case .pending: break
    case .computed: if outcome == .finished { fields[LedgerField.costComputed] = .int(cost.nanoUSD) }
    case .reported: fields[LedgerField.costReported] = .int(cost.nanoUSD)
    }
    return fields
  }

  private static func encode(_ usage: TokenUsage) -> JSONValue {
    .object([
      LedgerUsageKey.input: .int(Int64(usage.input)),
      LedgerUsageKey.output: .int(Int64(usage.output)),
      LedgerUsageKey.cacheRead: .int(Int64(usage.cacheRead)),
      LedgerUsageKey.cacheWriteShort: .int(Int64(usage.cacheWriteShort)),
      LedgerUsageKey.cacheWriteLong: .int(Int64(usage.cacheWriteLong)),
    ])
  }

  private static func decode(_ ref: EntityRef, _ state: EntityState) throws(Malformed) -> ModelCallEntry {
    guard case .record(let record) = state, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { throw Malformed() }
    guard
      let call = record[field: LedgerField.call]?.value.objectValue,
      let provider = call[LedgerCallKey.provider]?.stringValue,
      let model = call[LedgerCallKey.model]?.stringValue,
      let task = call[LedgerCallKey.task]?.stringValue.flatMap(ModelTask.init(rawValue:)),
      let started = call[LedgerCallKey.started]?.intValue,
      let outcome = record[field: LedgerField.outcome]?.value.stringValue.flatMap(LedgerOutcome.init(rawValue:))
    else { throw Malformed() }
    let pace = try optionalText(call[LedgerCallKey.pace]).map { name throws(Malformed) in
      guard let pace = Pace(rawValue: name) else { throw Malformed() }
      return pace
    }
    let parent = try optionalText(call[LedgerCallKey.parent]).map { text throws(Malformed) in
      guard let parent = UUID(uuidString: text) else { throw Malformed() }
      return parent
    }
    let reported = try decodeCost(record[field: LedgerField.costReported]?.value)
    let computed = try decodeCost(record[field: LedgerField.costComputed]?.value)
    let requestID = try optionalText(record[field: LedgerField.requestID]?.value)
    let generationID = try optionalText(record[field: LedgerField.generationID]?.value)
    let isUnbillable = (outcome == .failed || outcome == .cancelled) && generationID == nil
    let priced: (cost: Cost?, source: LedgerCostSource) =
      if let reported { (reported, .reported) } else if let computed { (computed, .computed) } else if isUnbillable { (.zero, .computed) } else { (nil, .pending) }
    return ModelCallEntry(
      id: id,
      provider: provider,
      model: model,
      task: task,
      pace: pace,
      startedMillis: started,
      parent: parent,
      requestID: requestID,
      generationID: generationID,
      outcome: outcome,
      usage: try decodeUsage(record[field: LedgerField.usage]?.value),
      cost: priced.cost,
      costSource: priced.source
    )
  }

  private static func optionalText(_ value: JSONValue?) throws(Malformed) -> String? {
    guard let value, !value.isNull else { return nil }
    guard let text = value.stringValue else { throw Malformed() }
    return text
  }

  private static func decodeCost(_ value: JSONValue?) throws(Malformed) -> Cost? {
    guard let value, !value.isNull else { return nil }
    guard let nanoUSD = value.intValue else { throw Malformed() }
    return Cost(nanoUSD: nanoUSD)
  }

  private static func decodeUsage(_ value: JSONValue?) throws(Malformed) -> TokenUsage {
    guard let value, !value.isNull else { return .zero }
    guard let counts = value.objectValue else { throw Malformed() }
    return TokenUsage(
      input: try count(counts[LedgerUsageKey.input]),
      output: try count(counts[LedgerUsageKey.output]),
      cacheRead: try count(counts[LedgerUsageKey.cacheRead]),
      cacheWriteShort: try count(counts[LedgerUsageKey.cacheWriteShort]),
      cacheWriteLong: try count(counts[LedgerUsageKey.cacheWriteLong])
    )
  }

  private static func count(_ value: JSONValue?) throws(Malformed) -> Int {
    guard let value else { return 0 }
    guard let number = value.intValue else { throw Malformed() }
    return Int(clamping: max(number, 0))
  }
}
