import Foundation

extension ReplayState {
  /// Every handler refuses before it changes anything, so a thrown refusal leaves the state as it was.
  mutating func apply(_ body: MemoirCommandBody, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    switch body {
    case .questCreate(let creation): return createQuest(creation, in: context)
    case .questUpdate(let update): return try updateQuest(update)
    case .questDelete(let reference): return try deleteQuest(reference)
    case .questComplete(let occurrence): return try resolveCompletion(occurrence, .full, in: context)
    case .questPartial(let occurrence): return try resolveCompletion(occurrence, .partial, in: context)
    case .questSkip(let action): return try resolveBreak(action, .skipped, in: context)
    case .questPostpone(let action): return try resolveBreak(action, .postponed, in: context)
    case .questReschedule(let action): return try reschedule(action, in: context)
    case .questAttachReason(let reason): return try attachReason(reason, in: context)
    case .questEditLog(let edit): return try editLog(edit, in: context)
    case .questDeleteLog(let occurrence): return try deleteLog(occurrence, in: context)
    case .recoveryComplete(let completion): return try completeRecovery(completion, in: context)
    case .planSetLock(let lock): return try setLock(lock, in: context)
    case .titleDisplay(let display): return try displayTitle(display)
    case .cosmeticPurchase(let cosmetic): return try purchaseCosmetic(cosmetic, in: context)
    case .cosmeticEquip(let cosmetic): return try equipCosmetic(cosmetic)
    case .journalSave(let entry): return try logFirstOfDay(entry.id, .journal, on: entry.date, link: .journal, type: .journal, in: context)
    case .mealLog(let entry): return try logFirstOfDay(entry.id, .meal, on: entry.date, link: .meal, type: .meal, in: context)
    case .mealLogPreset(let entry): return try logPresetMeal(entry, in: context)
    case .mealSavePreset(let reference): return savePreset(reference)
    case .mealPresetUpdate(let reference): return try updatePreset(reference)
    case .mealPresetDelete(let reference): return try deletePreset(reference)
    case .weightSave(let entry): return try saveWeight(entry, in: context)
    case .sideQuestLog(let entry): return try logSideQuest(entry, in: context)
    case .receiptScan: return scanReceipt(in: context)
    case .metricCreate(let metric): return createMetric(metric)
    case .metricUpdate(let metric): return try updateMetric(metric)
    case .metricDelete(let deletion): return try deleteMetric(deletion)
    case .metricRegister(let registration): return try registerMetric(registration)
    case .expenseCreate(let creation): return createExpense(creation)
    case .expenseUpdate(let reference): return try updateExpense(reference)
    case .expenseDelete(let reference): return try deleteExpense(reference)
    case .subscriptionCreate(let reference): return createSubscription(reference)
    case .subscriptionUpdate(let reference): return try updateSubscription(reference)
    case .subscriptionDelete(let reference): return try deleteSubscription(reference)
    case .subscriptionConfirmCycle(let confirmation): return try confirmCycle(confirmation, in: context)
    case .categorySetArchived: return .applied
    case .accountSetTimeZone(let change): return setTimeZone(change, in: context)
    case .accountSetIntensityMode(let change): return setIntensityMode(change, in: context)
    case .accountSetReturnerThreshold(let change): return setReturnerThreshold(change, in: context)
    case .moneyNoSpend, .budgetClosePeriod, .goalMilestone, .goalBought: throw .needsNewerRuleset(minimum: body.minimumRulesetVersion)
    }
  }
}
