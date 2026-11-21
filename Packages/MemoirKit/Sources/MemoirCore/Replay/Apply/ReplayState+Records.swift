import Foundation
import ShadowCore

/// Metrics, finance and settings. Only a confirmed subscription cycle moves hero state; the rest is judged against what earlier commands named, so a
/// refusal reads as the reference's code. A metric's value never reaches replay.
extension ReplayState {
  mutating func createMetric(_ metric: MetricReference) -> ReplayOutcome {
    guard records.metrics[metric.id] == nil else { return .superseded }
    records.metrics[metric.id] = ReplayMetric(metricClass: metric.metricClass, isActive: true)
    return .applied
  }

  mutating func updateMetric(_ metric: MetricReference) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.metrics[metric.id] != nil else { throw .metricNotFound }
    return .applied
  }

  /// No quest declares a metric as a consequence natively, so the reference's `MET_004` (delete without `detach`) never arises.
  mutating func deleteMetric(_ deletion: MetricDeletion) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.metrics[deletion.metric.id] != nil else { throw .metricNotFound }
    records.metrics[deletion.metric.id]?.isActive = false
    return .applied
  }

  mutating func registerMetric(_ registration: MetricRegistration) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.metrics[registration.metric.id] != nil else { throw .metricNotFound }
    return .applied
  }

  mutating func createExpense(_ creation: ExpenseCreation) -> ReplayOutcome {
    records.expenses.insert(creation.id)
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

  mutating func setTimeZone(_ change: TimeZoneChange, in context: ApplyContext) -> ReplayOutcome {
    guard let firstDay = firstDay(of: .accountSetTimeZone, replacingValueInForce: !settings.timeZones.isEmpty, in: context) else { return .applied }
    settings.timeZones.append(SettingChange(firstDay: firstDay, value: change.identifier, command: context.id, order: context.order))
    return .applied
  }

  mutating func setIntensityMode(_ change: IntensityModeChange, in context: ApplyContext) -> ReplayOutcome {
    guard let firstDay = firstDay(of: .accountSetIntensityMode, replacingValueInForce: true, in: context) else { return .applied }
    settings.intensityModes.append(SettingChange(firstDay: firstDay, value: change.mode, command: context.id, order: context.order))
    return .applied
  }

  mutating func setReturnerThreshold(_ change: ReturnerThresholdChange, in context: ApplyContext) -> ReplayOutcome {
    guard let firstDay = firstDay(of: .accountSetReturnerThreshold, replacingValueInForce: true, in: context) else { return .applied }
    settings.returnerThresholds.append(SettingChange(firstDay: firstDay, value: change.days, command: context.id, order: context.order))
    return .applied
  }

  /// Nil only when the day after the account's day leaves the calendar, so the change never takes effect.
  private func firstDay(of kind: MemoirCommandKind, replacingValueInForce: Bool, in context: ApplyContext) -> LocalDate? {
    kind.settingTiming?.firstDay(issuedOn: context.issuedOn, openDay: openDay, replacingValueInForce: replacingValueInForce)
  }
}
