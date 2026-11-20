import MemoirCore
import Testing

@Suite("Streak and HP vectors", TestTimeLimit.standard)
struct StreakHPVectorTests {
  private let ruleset = Ruleset.v1

  @Test("should apply a streak only where the strictness and opt-in allow it")
  func streakApplies() throws {
    try RuleVectors.check("streak.json", "streakApplies") { .bool(ruleset.streakApplies(to: try $0["strictness"].key(), optIn: try $0["optIn"].bool)) }
  }

  @Test("should hold, bridge, break or ignore every log state from every grid state")
  func applyStreakEvent() throws {
    try RuleVectors.check("streak.json", "applyStreakEvent") { FixtureValue(ruleset.applyStreakEvent(try $0["event"].streakEvent, to: try $0["state"].streakState)) }
  }

  @Test("should grant shields up to the cap and hold the rest pending")
  func grantStreakShields() throws {
    try RuleVectors.check("streak.json", "grantStreakShield") { input in
      let result = ruleset.grantStreakShields(try input["count"].int, to: try input["state"].streakState)
      return .object(["state": FixtureValue(result.state), "granted": .int(result.granted), "heldPending": .int(result.heldPending)])
    }
  }

  @Test("should recompute a streak from its history and an optional initial state")
  func recomputeStreak() throws {
    try RuleVectors.check("streak.json", "recomputeStreak") { input in
      let events = try input["events"].array.map { try $0.streakEvent }
      let initial = try input["initial"]
      return FixtureValue(initial == .null ? ruleset.recomputeStreak(events) : ruleset.recomputeStreak(events, from: try initial.streakState))
    }
  }

  @Test("should cap, regenerate and charge HP as the reference does")
  func hp() throws {
    try RuleVectors.check("hp.json", "hpMaxFor") { .int(ruleset.hpMax(for: try $0.key())) }
    try RuleVectors.check("hp.json", "hpStartFor") { .int(ruleset.hpStart(for: try $0["mode"].key(), previousHPEnd: try $0["previous"].optionalInt)) }
    try RuleVectors.check("hp.json", "hpCostFor") { .int(ruleset.hpCost(of: try $0["event"].hpBreak, in: try $0["mode"].key())) }
    try RuleVectors.check("hp.json", "computeDayHp") { input in
      let day = ruleset.dayHP(in: try input["mode"].key(), previousHPEnd: try input["previousHpEnd"].optionalInt, breaks: try input["breaks"].array.map { try $0.hpBreak })
      return .object(["hpStart": .int(day.hpStart), "hpEnd": .int(day.hpEnd), "hpMax": .int(day.hpMax), "spent": .int(day.spent)])
    }
    try RuleVectors.check("hp.json", "energyLowIndicated") { .bool((try $0["mode"].key() as IntensityMode).indicatesLowEnergy(missesToday: try $0["misses"].int)) }
  }

  @Test("should saturate instead of trapping on counters at the edge of the integer range")
  func saturates() {
    let full = StreakState(currentDays: .max, longestDays: .max, shields: .min, completionsTowardShield: .max, pendingShieldGrant: .max)
    let event = StreakEvent(state: .completed, strictness: .anchor, intensityMode: .standard, streakOptIn: false, onTime: true)
    #expect(ruleset.applyStreakEvent(event, to: full).state.currentDays == .max)
    #expect(ruleset.grantStreakShields(.max, to: full).state.pendingShieldGrant >= 0)
    #expect(ruleset.hpStart(for: .standard, previousHPEnd: .max) == 5)
  }
}
