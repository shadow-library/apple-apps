import Foundation
import ShadowCore
import ShadowStore

private struct SpentCall {
  let startedMillis: Int64
  let cost: Cost?
  let source: LedgerCostSource
}

extension Spend {
  private static let fields = [LedgerField.call, LedgerField.outcome, LedgerField.generationID, LedgerField.costReported, LedgerField.costComputed]

  /// `summary(of: Ledger.entries(in:))` without decoding or sorting whole entries, for the check before each call; like `entries`, it skips a call whose facts, outcome, ids
  /// or costs are malformed, but it does not read the usage. Nil when the calendar gives no month or day for `now`, so a caller can refuse rather than read zero.
  public static func summary(in transaction: ReadTransaction, now: Date, calendar: Calendar) throws(StoreError) -> SpendSummary? {
    guard let thisMonth = calendar.dateInterval(of: .month, for: now), let thisDay = calendar.dateInterval(of: .day, for: now) else { return nil }
    var today = Cost.zero
    var month = Cost.zero
    var pending = 0
    for call in try transaction.fieldValues(ofKind: LedgerSchema.modelCallKind, named: fields).values.lazy.compactMap(spentCall) {
      let started = Date(timeIntervalSince1970: Double(call.startedMillis) / 1_000)
      guard thisMonth.start <= started, started < thisMonth.end else { continue }
      guard call.source != .pending else {
        pending += 1
        continue
      }
      let cost = Cost(nanoUSD: max(call.cost?.nanoUSD ?? 0, 0))
      month = saturatingAdd(month, cost)
      if thisDay.start <= started, started < thisDay.end { today = saturatingAdd(today, cost) }
    }
    return SpendSummary(today: today, month: month, pendingCalls: pending)
  }

  private static func spentCall(_ fields: [String: JSONValue]) -> SpentCall? {
    guard
      let call = fields[LedgerField.call]?.objectValue,
      call[LedgerCallKey.provider]?.stringValue != nil,
      call[LedgerCallKey.model]?.stringValue != nil,
      call[LedgerCallKey.task]?.stringValue.flatMap(ModelTask.init(rawValue:)) != nil,
      let started = call[LedgerCallKey.started]?.intValue,
      optional(call[LedgerCallKey.pace], { $0.stringValue.flatMap(Pace.init(rawValue:)) }) != nil,
      optional(call[LedgerCallKey.parent], { $0.stringValue.flatMap(UUID.init(uuidString:)) }) != nil,
      let outcome = fields[LedgerField.outcome]?.stringValue.flatMap(LedgerOutcome.init(rawValue:)),
      let reported = optional(fields[LedgerField.costReported], \.intValue),
      let computed = optional(fields[LedgerField.costComputed], \.intValue),
      let generationID = optional(fields[LedgerField.generationID], \.stringValue)
    else { return nil }
    let isUnbillable = (outcome == .failed || outcome == .cancelled) && generationID == nil
    if let reported { return SpentCall(startedMillis: started, cost: Cost(nanoUSD: reported), source: .reported) }
    if let computed { return SpentCall(startedMillis: started, cost: Cost(nanoUSD: computed), source: .computed) }
    return isUnbillable ? SpentCall(startedMillis: started, cost: .zero, source: .computed) : SpentCall(startedMillis: started, cost: nil, source: .pending)
  }

  private static func saturatingAdd(_ lhs: Cost, _ rhs: Cost) -> Cost {
    let (sum, overflow) = lhs.nanoUSD.addingReportingOverflow(rhs.nanoUSD)
    return Cost(nanoUSD: overflow ? Int64.max : sum)
  }

  /// `.some(nil)` for an absent or null field, `nil` for a value of the wrong type.
  private static func optional<Value>(_ value: JSONValue?, _ read: (JSONValue) -> Value?) -> Value?? {
    guard let value, !value.isNull else { return .some(nil) }
    return read(value).map { .some($0) }
  }
}
