import MemoirCore
import Testing

/// The seeded cases of the reference's properties.spec.ts: each matches the reference output and holds the property natively.
@Suite("Rule property vectors", TestTimeLimit.property)
struct RulePropertyVectorTests {
  private let ruleset = Ruleset.v1

  @Test("should keep the comeback net negative and its bonus within one coin")
  func comebackStaysNegative() throws {
    try RuleVectors.check("properties.json", "comebackNetNegative") { input in
      let net = ruleset.comebackNetXP(forgone: try input["forgone"].rewardInput, claimed: try input["claimed"].rewardInput)
      #expect(net < 0)
      return .int(net)
    }
    try RuleVectors.check("properties.json", "comebackBonusCoins") { input in
      let bonus = ruleset.comebackBonus(claimed: try input.rewardInput)
      #expect(bonus.coins <= ruleset.reward.comebackCoinBonus)
      return FixtureValue(bonus)
    }
  }

  @Test("should never let a recovery or a non-opted optional quest cost HP, move a streak or arm a comeback")
  func compassionNeverCascades() throws {
    try RuleVectors.check("properties.json", "recoveryNeutral") { input in
      let hpCost = ruleset.hpCost(of: try input["hpBreak"].hpBreak, in: try input["intensityMode"].key())
      let streak = try input["streak"].streakState
      let transition = ruleset.applyStreakEvent(try input["event"].streakEvent, to: streak)
      #expect(hpCost == 0 && transition.outcome == .neutral && transition.state == streak)
      return .object(["hpCost": .int(hpCost), "transition": FixtureValue(transition)])
    }
    try RuleVectors.check("properties.json", "optionalNeutralHp") { input in
      let cost = ruleset.hpCost(of: try input["event"].hpBreak, in: try input["mode"].key())
      #expect(cost == 0)
      return .int(cost)
    }
    try RuleVectors.check("properties.json", "optionalNeutralStreak") { input in
      let streak = try input["state"].streakState
      let transition = ruleset.applyStreakEvent(try input["event"].streakEvent, to: streak)
      #expect(transition.outcome == .neutral && transition.state == streak)
      return FixtureValue(transition)
    }
    for function in ["recoveryMissesNeverArm", "optionalMissesNeverArm"] {
      try RuleVectors.check("properties.json", function) { input in
        let arming = ruleset.comebackArming(for: try input.comebackArmingInput)
        #expect(!arming.isArmed)
        return FixtureValue(arming)
      }
    }
    #expect(ruleset.crownWeight(for: .recovery) == .zero && ruleset.crownWeight(for: .optional) == .zero)
  }

  @Test("should never shorten the longest streak or exceed the shield cap over forty days")
  func streakSequences() throws {
    try RuleVectors.check("properties.json", "streakSequences") { input in
      var state = StreakState.empty
      return .array(
        try input.array.map { step in
          let fields = try step.array
          guard fields.count == 4 else { throw FixtureError.malformed("streak step \(step)") }
          let event = StreakEvent(
            state: try fields[0].key(), strictness: try fields[1].key(), intensityMode: try fields[2].key(), streakOptIn: false, onTime: try fields[3].bool)
          let transition = ruleset.applyStreakEvent(event, to: state)
          #expect(transition.state.longestDays >= state.longestDays && transition.state.longestDays >= transition.state.currentDays)
          #expect(transition.state.shields <= ruleset.shields.capPerQuest)
          state = transition.state
          return .array([
            .string(transition.outcome.rawValue), .int(state.currentDays), .int(state.longestDays), .int(state.shields), .int(state.completionsTowardShield),
            .int(state.pendingShieldGrant),
          ])
        })
    }
  }

  @Test("should keep a day's HP within zero and the maximum and spend no more than its breaks allow")
  func dayHP() throws {
    try RuleVectors.check("properties.json", "dayHp") { input in
      let mode: IntensityMode = try input["mode"].key()
      let breaks = try input["breaks"].array.map { try $0.hpBreak }
      let day = ruleset.dayHP(in: mode, previousHPEnd: try input["previousHpEnd"].optionalInt, breaks: breaks)
      #expect((0...day.hpMax).contains(day.hpEnd))
      #expect(day.spent <= breaks.count * ruleset.intensityModes[mode].hpCost.perBreakEndingHighStreak)
      return .object(["hpStart": .int(day.hpStart), "hpEnd": .int(day.hpEnd), "hpMax": .int(day.hpMax), "spent": .int(day.spent)])
    }
  }

  @Test("should never revoke an achievement or a title as counters grow")
  func progressions() throws {
    try RuleVectors.check("properties.json", "progressions") { input in
      var counters = ProgressCounters.empty
      var titles = Set<TitleID>()
      return .array(
        try input.array.map { step in
          let deltas = try step.array.map { try $0.int }
          guard deltas.count == 12 else { throw FixtureError.malformed("progression step \(step)") }
          counters.totalXP += deltas[0]
          counters.level += deltas[1]
          counters.questsCompleted += deltas[2]
          counters.longestStreakDays += deltas[3]
          counters.longestAnchorStreakDays += deltas[4]
          counters.questsReachingSilverStreak += deltas[5]
          counters.crownsBanked += deltas[6]
          counters.activeDays += deltas[7]
          for (index, stat) in StatAffinity.allCases.enumerated() { counters.stats[stat] += deltas[8 + index] }
          let satisfied = ruleset.satisfiedTitles(counters)
          #expect(titles.isSubset(of: satisfied))
          titles.formUnion(satisfied)
          return .object(["achievements": .keys(ruleset.satisfiedAchievements(counters)), "titles": .keys(satisfied)])
        })
    }
  }
}
