extension Ruleset {
  /// Published and frozen: a change here alters closed history, so a new ruleset gets a new version instead.
  public static let v1 = Ruleset(
    version: 1,
    strictness: RuleTable { strictness in
      switch strictness {
      case .anchor: StrictnessRules(.strictTime, crownHalves: 3, costsHP: true, triggersRecovery: true, streak: .always, postpone: true, oneShot: true)
      case .routine: StrictnessRules(.timeWindow, crownHalves: 2, costsHP: true, triggersRecovery: true, streak: .always, postpone: true, oneShot: true)
      case .goal: StrictnessRules(.dayLevel, crownHalves: 2, costsHP: false, triggersRecovery: false, streak: .always, postpone: true, oneShot: false)
      case .recovery: StrictnessRules(.dayLevel, crownHalves: 0, costsHP: false, triggersRecovery: false, streak: .never, postpone: false, oneShot: false)
      case .optional: StrictnessRules(.dayLevel, crownHalves: 0, costsHP: false, triggersRecovery: false, streak: .optIn, postpone: false, oneShot: false)
      }
    },
    reward: RewardRules(
      baseXP: RuleTable { strictness in
        switch strictness {
        case .anchor: .bands(12, 8, 5, 3, 1, 0, 0)
        case .routine: .bands(10, 7, 5, 2, 1, 0, 0)
        case .goal: .bands(8, 8, 8, 2, 1, 0, 0)
        case .recovery: .bands(5, 5, 5, 0, 0, 0, 0)
        case .optional: .bands(8, 8, 8, 1, 0, 0, 0)
        }
      },
      baseCoins: RuleTable { strictness in
        switch strictness {
        case .anchor: 2
        case .routine, .goal, .optional: 1
        case .recovery: 0
        }
      },
      partialXPFactor: Thousandths(500),
      lockXPModifier: Thousandths(1100),
      oneShotXPModifiers: OneShotXPModifiers(returner: Thousandths(1200), comeback: Thousandths(1500)),
      comebackCoinBonus: 1,
      xpCeiling: 25,
      statTick: 1,
      timing: TimingRules(anchorGraceMinutes: 30, lateStepMinutes: 120)
    ),
    level: .v1,
    streaks: StreakRules(
      floorTier: StreakTier(id: .none, minDays: 0, xpModifier: Thousandths(1000)),
      higherTiers: [
        StreakTier(id: .bronze, minDays: 3, xpModifier: Thousandths(1000)),
        StreakTier(id: .silver, minDays: 7, xpModifier: Thousandths(1100)),
        StreakTier(id: .gold, minDays: 30, xpModifier: Thousandths(1200)),
        StreakTier(id: .platinum, minDays: 100, xpModifier: Thousandths(1300)),
      ],
      breakAnnounceMinDays: 7
    ),
    shields: ShieldRules(capPerQuest: 2, expires: false, returnerGrant: 1),
    intensityModes: RuleTable { mode in
      switch mode {
      case .standard:
        IntensityModeRules(
          hpMax: 5,
          overnightHPRegen: 3,
          crownCadence: .daily,
          shieldEarnCadence: 7,
          hpCost: HPCostRules(perBreak: 1, perBreakEndingHighStreak: 1),
          comebackTriggers: [.missWithinDays(days: 3, strictness: [.anchor], requiresColdMomentum: true), .anchorMissYesterday]
        )
      case .lowIntensity:
        IntensityModeRules(
          hpMax: 8,
          overnightHPRegen: 5,
          crownCadence: .weekly,
          shieldEarnCadence: 5,
          hpCost: HPCostRules(perBreak: 0, perBreakEndingHighStreak: 0),
          comebackTriggers: [.missWithinDays(days: 3, strictness: [.anchor, .routine], requiresColdMomentum: false)]
        )
      case .highIntensity:
        IntensityModeRules(
          hpMax: 3,
          overnightHPRegen: 2,
          crownCadence: .daily,
          shieldEarnCadence: 10,
          hpCost: HPCostRules(perBreak: 1, perBreakEndingHighStreak: 2),
          comebackTriggers: [.anchorMissYesterday]
        )
      }
    },
    crown: CrownRules(xpPerWeight: 4, coinsWeightDivisor: 2, maxCoins: 5, weeklyAnchorWeekday: .monday),
    recovery: RecoveryRules(maxPerDay: 1, triggeredByStrictness: [.anchor, .routine]),
    comeback: ComebackRules(maxFiresPerDay: 1, maxFiresPerDayViaRecovery: 2),
    returner: ReturnerRules(defaultThresholdDays: 7, shieldGrant: 1, suppressesComeback: true),
    momentum: MomentumRules(recentDayWeights: [Tenths(10), Tenths(7), Tenths(5)], medianWindowDays: 14, coldBelowRatio: Thousandths(300), warmAboveRatio: Thousandths(1100)),
    capacity: CapacityRules(
      newUserBaselineCap: 14,
      ratchetFactor: Thousandths(1150),
      medianWindowDays: 14,
      coldMomentumFactor: Thousandths(700),
      heavyMissDayFactor: Thousandths(850),
      softWarningRatio: Thousandths(1000),
      modalWarningRatio: Thousandths(1300),
      softWarningThrottleDays: 7,
      anchorWarnAboveCount: 3
    ),
    reasonTags: ReasonTag.allCases,
    quickLogs: RuleTable { source in
      switch source {
      case .journal: QuickLogReward(xp: 5, coins: 0, statTick: 0, maxRewardedPerDay: 1)
      case .meal, .weight: QuickLogReward(xp: 3, coins: 0, statTick: 0, maxRewardedPerDay: 1)
      case .sideQuest: QuickLogReward(xp: 8, coins: 1, statTick: 1, maxRewardedPerDay: 3)
      }
    },
    subscriptionConfirmationCoins: 1
  )
}

extension StrictnessRules {
  fileprivate init(
    _ model: SchedulingModel, crownHalves: Int, costsHP: Bool, triggersRecovery: Bool, streak: StreakEligibility, postpone: Bool, oneShot: Bool
  ) {
    self.init(
      schedulingModel: model, crownWeight: Halves(crownHalves), incursHPCost: costsHP, triggersRecovery: triggersRecovery, streakEligibility: streak,
      allowsPostpone: postpone, consumesOneShot: oneShot)
  }
}

extension RuleTable where Key == TimingBand, Value == Int {
  fileprivate static func bands(_ onTime: Int, _ late0To2h: Int, _ late2hPlus: Int, _ day1: Int, _ day2: Int, _ day3: Int, _ day4: Int) -> Self {
    RuleTable { band in
      switch band {
      case .onTime: onTime
      case .late0To2h: late0To2h
      case .late2hPlus: late2hPlus
      case .day1: day1
      case .day2: day2
      case .day3: day3
      case .day4: day4
      }
    }
  }
}
