extension HeroEventType {
  /// The module whose data the event reveals: a quest's outcome, the day's crown, a recovery or returner, a logging day, or a budget close, money log or
  /// savings goal. Only level, achievement and coin events are the hero's own.
  public var sourceModule: MemoirModule {
    switch self {
    case .questComplete, .questPartial, .questLate, .recovery, .recoverySpawned, .recoveryCompleted, .recoveryExpired, .crownBanked, .crownInit, .crownForfeit,
      .sideQuest, .returnerFired:
      .quests
    case .journal: .journal
    case .meal: .meals
    case .weight: .body
    case .moneyFine, .moneyReward, .moneyLog, .goalMilestone, .goalBought: .money
    case .levelUp, .achievementUnlock, .coinGrant, .coinSpend: .hero
    }
  }
}
