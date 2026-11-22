import Foundation

/// `quick-logs-commands.service.ts`: the first log of a kind on the account's day earns its reward once, keyed `<kind>_<date>`; a backdated entry, or
/// one a scheduled quest of the same module could take, earns nothing, so the quest's own completion carries the reward.
extension ReplayState {
  mutating func logFirstOfDay(
    _ id: UUID, _ source: QuickLogSource, on date: LocalDate, link: QuestModuleLink, type: HeroEventType, in context: ApplyContext
  ) throws(ReplayRefusal) -> ReplayOutcome {
    let reward = try grantFirstOfDay(source, on: date, link: link, type: type, in: context)
    records.quickLogs[id] = QuickLogOutcome(source: source, date: date, reward: reward)
    return .applied
  }

  mutating func logPresetMeal(_ entry: PresetMealEntry, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.mealPresets.contains(entry.presetId) else { throw .mealPresetNotFound }
    return try logFirstOfDay(entry.id, .meal, on: entry.date, link: .meal, type: .meal, in: context)
  }

  mutating func savePreset(_ reference: RecordReference) -> ReplayOutcome {
    records.mealPresets.insert(reference.id)
    return .applied
  }

  mutating func updatePreset(_ reference: RecordReference) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.mealPresets.contains(reference.id) else { throw .mealPresetNotFound }
    return .applied
  }

  mutating func deletePreset(_ reference: RecordReference) throws(ReplayRefusal) -> ReplayOutcome {
    guard records.mealPresets.remove(reference.id) != nil else { throw .mealPresetNotFound }
    return .applied
  }

  /// A day's weight is replaced only with the owner's confirmation, and a replacement earns nothing.
  mutating func saveWeight(_ entry: WeightEntry, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    guard !records.weightDates.contains(entry.date) else { return entry.confirmedReplacement ? .applied : .rejected(.weightNeedsConfirmation) }
    _ = try grantFirstOfDay(.weight, on: entry.date, link: .weight, type: .weight, in: context)
    records.weightDates.insert(entry.date)
    return .applied
  }

  /// The first side quests of the account's day each take the next reward slot, keyed `sidequest_<date>_<slot>`.
  mutating func logSideQuest(_ entry: SideQuestEntry, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    let reward = context.ruleset.quickLogs[.sideQuest]
    let rewardedToday = records.sideQuestsRewarded[entry.date] ?? 0
    var credited: RewardAmount?
    if entry.date == context.accountDay && rewardedToday < reward.maxRewardedPerDay {
      let slot = rewardedToday + 1
      credited = Self.credited(
        hero.credit(
          [
            GrantIntent(
              key: "sidequest_\(entry.date)_\(slot)", type: .sideQuest, date: entry.date, xpDelta: reward.xp, coinsDelta: reward.coins,
              statAffinity: entry.statAffinity, statDelta: reward.statTick)
          ], ruleset: context.ruleset))
      if credited != nil { records.sideQuestsRewarded[entry.date] = slot }
    }
    records.quickLogs[entry.id] = QuickLogOutcome(source: .sideQuest, date: entry.date, reward: credited)
    return .applied
  }

  mutating func scanReceipt(in context: ApplyContext) -> ReplayOutcome {
    onReceiptScanned(date: context.accountDay, ruleset: context.ruleset)
    return .applied
  }

  /// Whether an active quest linked to this module is scheduled on the day, completed or not; either way the log's own reward is withheld.
  public func linkedQuestExists(_ link: QuestModuleLink, on date: LocalDate) -> Bool {
    quests.values.contains { $0.isActive && $0.schedule.moduleLink == link && recurrenceCursors.occurs($0, on: date) }
  }

  private mutating func grantFirstOfDay(
    _ source: QuickLogSource, on date: LocalDate, link: QuestModuleLink, type: HeroEventType, in context: ApplyContext
  ) throws(ReplayRefusal) -> RewardAmount? {
    guard date == context.accountDay, !linkedQuestExists(link, on: date) else { return nil }
    let reward = context.ruleset.quickLogs[source]
    return Self.credited(
      hero.credit(
        [GrantIntent(key: "\(source.rawValue)_\(date)", type: type, date: date, xpDelta: reward.xp, coinsDelta: reward.coins)], ruleset: context.ruleset))
  }

  /// What the grants added to the hero, or nil when one was already in the trail.
  private static func credited(_ outcomes: [GrantOutcome]) -> RewardAmount? {
    guard outcomes.allSatisfy(\.isApplied) else { return nil }
    return RewardAmount(xp: Exact.sum(outcomes.map(\.event.xpDelta)), coins: Exact.sum(outcomes.map(\.event.coinsDelta)))
  }
}
