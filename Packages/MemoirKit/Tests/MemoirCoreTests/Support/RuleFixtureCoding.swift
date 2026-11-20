import MemoirCore

extension FixtureValue {
  var rewardInput: RewardInput {
    get throws {
      RewardInput(
        strictness: try self["strictness"].key(),
        band: try self["band"].key(),
        completion: try self["completion"].key(),
        streakDays: try self["streakDays"].int,
        lockActive: try self["lockActive"].bool,
        oneShot: try self["oneShot"].key()
      )
    }
  }

  var streakState: StreakState {
    get throws {
      StreakState(
        currentDays: try self["currentDays"].int,
        longestDays: try self["longestDays"].int,
        shields: try self["shields"].int,
        completionsTowardShield: try self["completionsTowardShield"].int,
        pendingShieldGrant: try self["pendingShieldGrant"].int
      )
    }
  }

  var streakEvent: StreakEvent {
    get throws {
      StreakEvent(
        state: try self["state"].key(),
        strictness: try self["strictness"].key(),
        intensityMode: try self["intensityMode"].key(),
        streakOptIn: try self["streakOptIn"].bool,
        onTime: try self["onTime"].bool
      )
    }
  }

  var hpBreak: HPBreak {
    get throws {
      HPBreak(
        occurrenceKey: try self["occurrenceKey"].string,
        strictness: try self["strictness"].key(),
        state: try self["state"].key(),
        shielded: try self["shielded"].bool,
        streakDaysBefore: try self["streakDaysBefore"].int
      )
    }
  }

  var crownDayState: CrownDayState {
    get throws {
      let ruleset = Ruleset.v1
      let endowed = try self["endowedWeight"].halves
      let forfeited = try self["forfeitedWeight"].halves
      let granted = RewardAmount(xp: try self["grantedXp"].int, coins: try self["grantedCoins"].int)
      let rebuilt = ruleset.forfeitCrownSlice(ruleset.endowCrown(weights: [endowed]), weight: forfeited)
      guard rebuilt.grantedXP == granted.xp, rebuilt.grantedCoins == granted.coins else {
        throw FixtureError.malformed("crown state \(self) was not endowed from its own weight")
      }
      return rebuilt
    }
  }

  var comebackDayState: ComebackDayState {
    get throws {
      ComebackDayState(armed: try self["armed"].bool, fires: try self["fires"].int, armedViaRecovery: try self["armedViaRecovery"].bool)
    }
  }

  var comebackArmingInput: ComebackArmingInput {
    get throws {
      ComebackArmingInput(
        intensityMode: try self["intensityMode"].key(),
        momentum: try self["momentum"].key(),
        returnerFired: try self["returnerFired"].bool,
        recentMisses: try self["recentMisses"].array.map { RecentMiss(daysAgo: try $0["daysAgo"].int, strictness: try $0["strictness"].key()) }
      )
    }
  }

  var progressCounters: ProgressCounters {
    get throws {
      var counters = ProgressCounters()
      counters.totalXP = try self["totalXp"].int
      counters.level = try self["level"].int
      for stat in StatAffinity.allCases { counters.stats[stat] = try self["stats"][stat.rawValue].int }
      counters.questsCompleted = try self["questsCompleted"].int
      for strictness in Strictness.allCases { counters.completionsByStrictness[strictness] = try self["completionsByStrictness"][strictness.rawValue].int }
      counters.longestStreakDays = try self["longestStreakDays"].int
      counters.longestAnchorStreakDays = try self["longestAnchorStreakDays"].int
      counters.questsReachingSilverStreak = try self["questsReachingSilverStreak"].int
      counters.subscriptionsConfirmed = try self["subscriptionsConfirmed"].int
      counters.receiptsScanned = try self["receiptsScanned"].int
      counters.fullHPDays = try self["fullHpDays"].int
      counters.crownsBanked = try self["crownsBanked"].int
      counters.lockedDaysCleared = try self["lockedDaysCleared"].int
      counters.comebackBonusesClaimed = try self["comebackBonusesClaimed"].int
      counters.returnerRitualsCompleted = try self["returnerRitualsCompleted"].int
      counters.completionsAfterReturner = try self["completionsAfterReturner"].int
      counters.reschedulesWithReasonIn90Days = try self["reschedulesWithReasonIn90Days"].int
      counters.reasonTaggedEvents = try self["reasonTaggedEvents"].int
      counters.activeDays = try self["activeDays"].int
      return counters
    }
  }

  init(_ outcome: RewardOutcome) {
    self = .object([
      "xp": .int(outcome.xp),
      "coins": .int(outcome.coins),
      "statTick": .int(outcome.statTick),
      "baseXp": .int(outcome.baseXP),
      "modifier": .fraction(outcome.modifier),
      "streakTier": .string(outcome.streakTier.rawValue),
      "oneShotConsumed": .string(outcome.oneShotConsumed.rawValue),
    ])
  }

  init(_ amount: RewardAmount) {
    self = .object(["xp": .int(amount.xp), "coins": .int(amount.coins)])
  }

  init(_ state: StreakState) {
    self = .object([
      "currentDays": .int(state.currentDays),
      "longestDays": .int(state.longestDays),
      "shields": .int(state.shields),
      "completionsTowardShield": .int(state.completionsTowardShield),
      "pendingShieldGrant": .int(state.pendingShieldGrant),
    ])
  }

  init(_ transition: StreakTransition) {
    self = .object([
      "outcome": .string(transition.outcome.rawValue),
      "state": FixtureValue(transition.state),
      "shieldsEarned": .int(transition.shieldsEarned),
      "shieldsConsumed": .int(transition.shieldsConsumed),
      "endedAtDays": .int(transition.endedAtDays),
      "announceBreak": .bool(transition.announceBreak),
      "milestone": .key(transition.milestone),
    ])
  }

  init(_ state: CrownDayState) {
    self = .object([
      "endowedWeight": .fraction(state.endowedWeight.fraction),
      "forfeitedWeight": .fraction(state.forfeitedWeight.fraction),
      "grantedXp": .int(state.grantedXP),
      "grantedCoins": .int(state.grantedCoins),
      "remainingXp": .int(state.remainingXP),
      "remainingCoins": .int(state.remainingCoins),
    ])
  }

  init(_ state: ComebackDayState) {
    self = .object(["armed": .bool(state.armed), "fires": .int(state.fires), "armedViaRecovery": .bool(state.armedViaRecovery)])
  }

  init(_ trigger: ComebackTrigger) {
    switch trigger {
    case .anchorMissYesterday:
      self = .object(["kind": .string("anchor_miss_yesterday")])
    case .missWithinDays(let days, let strictness, let requiresColdMomentum):
      self = .object([
        "kind": .string("miss_within_days"), "days": .int(days), "strictness": .keys(strictness), "requiresColdMomentum": .bool(requiresColdMomentum),
      ])
    }
  }

  init(_ arming: ComebackArming) {
    let suppressed = arming == .suppressedByReturner
    self = .object(["armed": .bool(arming.isArmed), "trigger": arming.trigger.map(FixtureValue.init) ?? .null, "suppressedByReturner": .bool(suppressed)])
  }

  init(_ momentum: Momentum) {
    self = .object([
      "weighted": .fraction(momentum.weighted.fraction),
      "median": .fraction(momentum.median.fraction),
      "ratio": momentum.ratio.map(FixtureValue.fraction) ?? .null,
      "bucket": .string(momentum.bucket.rawValue),
    ])
  }
}
