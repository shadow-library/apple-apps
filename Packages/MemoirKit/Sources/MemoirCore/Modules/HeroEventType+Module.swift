extension HeroEventType {
  /// The module whose data the event reveals: a quest's outcome, the day's crown, a recovery or returner, or a logging day. Only level, achievement and
  /// coin events are the hero's own.
  public var sourceModule: MemoirModule {
    switch self {
    case .questComplete, .questPartial, .questLate, .recovery, .recoverySpawned, .recoveryCompleted, .recoveryExpired, .crownBanked, .crownInit, .crownForfeit,
      .sideQuest, .returnerFired:
      .quests
    case .journal: .journal
    case .meal: .meals
    case .weight: .body
    case .levelUp, .achievementUnlock, .coinGrant, .coinSpend: .hero
    }
  }
}
