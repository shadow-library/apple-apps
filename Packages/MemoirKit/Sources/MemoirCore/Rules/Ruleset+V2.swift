extension Ruleset {
  /// Published and frozen: v1's tables unchanged, plus money in the game.
  public static let v2 = Ruleset(
    version: 2,
    strictness: v1.strictness,
    reward: v1.reward,
    level: v1.level,
    streaks: v1.streaks,
    shields: v1.shields,
    intensityModes: v1.intensityModes,
    crown: v1.crown,
    recovery: v1.recovery,
    comeback: v1.comeback,
    returner: v1.returner,
    momentum: v1.momentum,
    capacity: v1.capacity,
    reasonTags: v1.reasonTags,
    quickLogs: v1.quickLogs,
    subscriptionConfirmationCoins: v1.subscriptionConfirmationCoins,
    money: .v2
  )
}
