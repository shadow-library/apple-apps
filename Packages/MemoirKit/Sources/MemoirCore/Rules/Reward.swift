public struct RewardInput: Sendable, Hashable {
  public var strictness: Strictness
  public var band: TimingBand
  public var completion: CompletionKind
  public var streakDays: Int
  public var lockActive: Bool
  public var oneShot: OneShotModifier

  public init(strictness: Strictness, band: TimingBand, completion: CompletionKind, streakDays: Int, lockActive: Bool, oneShot: OneShotModifier) {
    self.strictness = strictness
    self.band = band
    self.completion = completion
    self.streakDays = streakDays
    self.lockActive = lockActive
    self.oneShot = oneShot
  }
}

public struct RewardOutcome: Sendable, Hashable {
  public let xp: Int
  public let coins: Int
  public let statTick: Int
  public let baseXP: Int
  public let modifier: Fraction
  public let streakTier: StreakTierID
  public let oneShotConsumed: OneShotModifier
}

extension Ruleset {
  public func streakTier(forStreakDays streakDays: Int) -> StreakTier {
    streaks.tiers.last { streakDays >= $0.minDays } ?? streaks.floorTier
  }

  public func streakTierMinDays(_ id: StreakTierID) -> Int? {
    streaks.tiers.first { $0.id == id }?.minDays
  }

  public func reward(for input: RewardInput) -> RewardOutcome {
    let tableXP = reward.baseXP[input.strictness][input.band]
    let baseXP =
      input.completion == .partial ? Int(clamping: Exact.floorDivide(Int128(tableXP) * Int128(reward.partialXPFactor.thousandths), 1000)) : tableXP

    let tier = streakTier(forStreakDays: input.streakDays)
    let oneShotConsumed = strictness[input.strictness].consumesOneShot ? input.oneShot : .none
    let lock = input.lockActive ? reward.lockXPModifier : Thousandths(1000)
    let oneShot =
      switch oneShotConsumed {
      case .none: Thousandths(1000)
      case .returner: reward.oneShotXPModifiers.returner
      case .comeback: reward.oneShotXPModifiers.comeback
      }
    let scaledModifier = Int128(tier.xpModifier.thousandths) * Int128(lock.thousandths) * Int128(oneShot.thousandths)
    let xp = min(reward.xpCeiling, Int(clamping: Exact.floorDivide(Int128(baseXP) * scaledModifier, 1_000_000_000)))

    let earnsBaseCoins = input.completion == .full && input.band == .onTime
    let coins = (earnsBaseCoins ? reward.baseCoins[input.strictness] : 0) + (oneShotConsumed == .comeback ? reward.comebackCoinBonus : 0)
    return RewardOutcome(
      xp: xp,
      coins: coins,
      statTick: reward.statTick,
      baseXP: baseXP,
      modifier: Fraction(reducing: scaledModifier, 1_000_000_000),
      streakTier: tier.id,
      oneShotConsumed: oneShotConsumed
    )
  }
}
