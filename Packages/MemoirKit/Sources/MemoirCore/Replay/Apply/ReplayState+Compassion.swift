import Foundation
import ShadowCore

/// `compassion-commands.service.ts` and `progression-commands.service.ts`. The compassion commands act on the account's open day alone.
extension ReplayState {
  /// Pending only: the reward goes through the ledger, then the day re-arms Comeback via the Recovery, lifting its fire allowance.
  mutating func completeRecovery(_ completion: RecoveryCompletion, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    try requireAccountDay(in: context)
    let ruleset = context.ruleset
    let date = context.accountDay
    guard var recovery = compassion.recoveries[date] else { throw .noPendingRecovery }
    guard recovery.state == .pending else { return .superseded }
    recovery.state = .completed
    recovery.reflection = completion.hasReflection ? context.id : nil
    recovery.completedAtMillis = context.instant
    compassion.recoveries[date] = recovery

    let reward = ruleset.reward(for: RewardInput(strictness: .recovery, band: .onTime, completion: .full, streakDays: 0, lockActive: false, oneShot: .none))
    _ = hero.credit(
      [
        GrantIntent(
          key: "recovery_completed_\(recovery.id.lowercasedString)", type: .recoveryCompleted, date: date, xpDelta: reward.xp, coinsDelta: reward.coins,
          quest: recovery.sourceQuest)
      ], ruleset: ruleset)
    onRecoveryQuestCompleted(date: date, ruleset: ruleset)

    guard var day = days[date], day.isOpen else { return .applied }
    day.comeback = day.comeback.armedViaRecoveryQuest()
    day.record(
      ComebackEvent(
        kind: .reArmed, trigger: nil, sourceLog: recovery.triggerLogs.first, consumedLog: nil, xpBonus: 0, coinBonus: 0, intensityMode: day.intensityMode))
    days[date] = day
    return .applied
  }

  /// The capacity a lock is measured against is advisory (`lockCapacity(on:plannedLoad:ruleset:)`) and never refuses it.
  mutating func setLock(_ lock: PlanLock, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    try requireAccountDay(in: context)
    guard var day = days[context.accountDay], day.isOpen else { throw .dayClosed }
    switch lock {
    case .unlocked:
      day.lock = nil
    case .locked(let questIDs):
      guard questIDs.allSatisfy({ quests[$0]?.isActive == true }) else { throw .lockedQuestNotFound }
      day.lock = DayLock(committedAtMillis: context.instant, quests: questIDs)
    }
    days[context.accountDay] = day
    return .applied
  }

  mutating func displayTitle(_ display: TitleDisplay) throws(ReplayRefusal) -> ReplayOutcome {
    if let title = display.title, progression.titles[title] == nil { throw .titleNotEarned(title) }
    progression.displayedTitle = display.title
    return .applied
  }

  /// A purchase that no longer fits the balance is refused (`HRO_001`), and `Replay.apply` tells the owner it was withdrawn.
  mutating func purchaseCosmetic(_ cosmetic: CosmeticID, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    guard progression.cosmetics[cosmetic] == nil, let price = cosmetic.priceCoins else { return .superseded }
    let outcomes = try hero.grant(
      [GrantIntent(key: "coinspend_\(cosmetic.rawValue)", type: .coinSpend, date: context.accountDay, coinsDelta: -price)], ruleset: context.ruleset)
    guard outcomes.allSatisfy(\.isApplied) else { return .superseded }
    progression.cosmetics[cosmetic] = OwnedCosmetic(source: .coin, equipped: false)
    return .applied
  }

  mutating func equipCosmetic(_ cosmetic: CosmeticID) throws(ReplayRefusal) -> ReplayOutcome {
    guard progression.cosmetics[cosmetic] != nil else { throw .cosmeticNotOwned(cosmetic) }
    for owned in progression.cosmetics.keys where owned.kind == cosmetic.kind { progression.cosmetics[owned]?.equipped = owned == cosmetic }
    return .applied
  }

  /// A command issued on a day the open day has passed is late, as the reference's `requireToday` refuses it (`CMD_002`), unless a backward zone change
  /// explains the gap: one that took effect after the issuing day and no later than the open day, which leaves the open day at most two days ahead of the
  /// new zone's date (offsets span 26 hours).
  private func requireAccountDay(in context: ApplyContext) throws(ReplayRefusal) {
    guard let openDay, context.issuedOn < openDay else { return }
    let explained =
      openDay.days(since: context.issuedOn) <= Self.maximumZoneLagDays && settings.timeZones.contains { $0.firstDay > context.issuedOn && $0.firstDay <= openDay }
    if !explained { throw .notAccountDay(context.issuedOn) }
  }

  static let maximumZoneLagDays = 2
}
