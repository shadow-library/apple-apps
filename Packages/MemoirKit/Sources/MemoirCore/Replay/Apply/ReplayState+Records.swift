import Foundation
import ShadowCore

/// Metrics, finance and settings. Only a confirmed subscription cycle and, under money rules, an expense's day move hero state; the rest is judged
/// against what earlier commands named, so a refusal reads as the reference's code. A metric's value never reaches replay.
extension ReplayState {
  /// A built-in metric exists on every device from the start (`BuiltinMetric`), so a create naming one finds it there.
  mutating func createMetric(_ metric: MetricReference) -> ReplayOutcome {
    guard BuiltinMetric(id: metric.id) == nil, records.metrics[metric.id] == nil else { return .superseded }
    records.metrics[metric.id] = ReplayMetric(metricClass: metric.metricClass, isActive: true)
    return .applied
  }

  mutating func updateMetric(_ metric: MetricReference) throws(ReplayRefusal) -> ReplayOutcome {
    try requireCustomMetric(metric.id)
    return .applied
  }

  /// No quest declares a metric as a consequence natively, so the reference's `MET_004` (delete without `detach`) never arises.
  mutating func deleteMetric(_ deletion: MetricDeletion) throws(ReplayRefusal) -> ReplayOutcome {
    try requireCustomMetric(deletion.metric.id)
    records.metrics[deletion.metric.id]?.isActive = false
    return .applied
  }

  mutating func registerMetric(_ registration: MetricRegistration) throws(ReplayRefusal) -> ReplayOutcome {
    guard BuiltinMetric(id: registration.metric.id) != nil || records.metrics[registration.metric.id] != nil else { throw .metricNotFound }
    return .applied
  }

  /// A creation that names its day covers that day's money logging when it is still inside the late window.
  mutating func createExpense(_ creation: ExpenseCreation, in context: ApplyContext) -> ReplayOutcome {
    records.expenses.insert(creation.id)
    noteMoneyActivity(in: context)
    if let date = creation.occurredOn, isInLoggingWindow(date, in: context) { cover(date, by: .expense, in: context) }
    return .applied
  }

  /// A saved expense's currency is a first-writer field of `ExpenseRecord`, so the reference's `FIN_006` is refused by the record write itself.
  mutating func updateExpense(_ reference: RecordReference) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.expenses.contains(reference.id) else { throw .expenseNotFound }
    return .applied
  }

  mutating func deleteExpense(_ reference: RecordReference) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.expenses.remove(reference.id) != nil else { throw .expenseNotFound }
    return .applied
  }

  mutating func createSubscription(_ reference: RecordReference) -> ReplayOutcome {
    records.subscriptions.insert(reference.id)
    return .applied
  }

  mutating func updateSubscription(_ reference: RecordReference) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.subscriptions.contains(reference.id) else { throw .subscriptionNotFound }
    return .applied
  }

  mutating func deleteSubscription(_ reference: RecordReference) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.subscriptions.remove(reference.id) != nil else { throw .subscriptionNotFound }
    return .applied
  }

  /// A cycle counts toward the subscription achievement and writes its expense when first confirmed; its coin is keyed by subscription and billing date, so it
  /// lands once.
  mutating func confirmCycle(_ confirmation: CycleConfirmation, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.subscriptions.contains(confirmation.subscription) else { throw .subscriptionNotFound }
    if records.confirmedCycles.insert(confirmation).inserted {
      records.expenses.insert(SubscriptionCycles.expenseID(for: confirmation))
      onSubscriptionConfirmed(date: confirmation.billingDate, ruleset: context.ruleset)
    }
    let key = "sub_\(confirmation.subscription.lowercasedString)_\(confirmation.billingDate)"
    _ = hero.credit(
      [GrantIntent(key: key, type: .coinGrant, date: confirmation.billingDate, coinsDelta: context.ruleset.subscriptionConfirmationCoins)], ruleset: context.ruleset)
    return .applied
  }

  /// A later staged change replaces an earlier one still waiting, as the reference's `PATCH /account` overwrites `pending_timezone`.
  mutating func setTimeZone(_ change: TimeZoneChange, in context: ApplyContext) -> ReplayOutcome {
    if MemoirCommandKind.accountSetTimeZone.settingTiming?.isStaged(replacingValueInForce: !settings.timeZones.isEmpty) == true {
      settings.pendingTimeZone = context.pendingSetting(change.identifier)
    } else {
      settings.timeZones.append(context.settingChange(change.identifier, from: context.accountDay))
    }
    return .applied
  }

  mutating func setIntensityMode(_ change: IntensityModeChange, in context: ApplyContext) -> ReplayOutcome {
    settings.pendingIntensityMode = context.pendingSetting(change.mode)
    return .applied
  }

  mutating func setReturnerThreshold(_ change: ReturnerThresholdChange, in context: ApplyContext) -> ReplayOutcome {
    settings.returnerThresholds.append(context.settingChange(change.days, from: context.accountDay))
    return .applied
  }

  /// A built-in keeps its definition and is never deleted (`MET_003`), as the reference's `builtin` metrics.
  private func requireCustomMetric(_ id: UUID) throws(ReplayRefusal) {
    if BuiltinMetric(id: id) != nil { throw .builtinMetric }
    guard records.metrics[id] != nil else { throw .metricNotFound }
  }
}
