import MemoirCore
import Testing

@Suite("Crown, comeback and returner vectors", TestTimeLimit.standard)
struct CrownComebackReturnerVectorTests {
  private let ruleset = Ruleset.v1

  @Test("should weigh, share, endow, forfeit, rescale and bank the crown in exact halves")
  func crown() throws {
    try RuleVectors.check("crown.json", "crownWeightFor") { .fraction(ruleset.crownWeight(for: try $0.key()).fraction) }
    try RuleVectors.check("crown.json", "crownCadenceFor") { .string(ruleset.crownCadence(for: try $0.key()).rawValue) }
    try RuleVectors.check("crown.json", "crownShare") { FixtureValue(ruleset.crownShare(weight: try $0.halves)) }
    try RuleVectors.check("crown.json", "endowCrown") { FixtureValue(ruleset.endowCrown(weights: try $0.array.map { try $0.halves })) }
    try RuleVectors.check("crown.json", "forfeitCrownSlice") { FixtureValue(ruleset.forfeitCrownSlice(try $0["state"].crownDayState, weight: try $0["weight"].halves)) }
    try RuleVectors.check("crown.json", "rescaleCrown") { input in
      FixtureValue(ruleset.rescaleCrown(try input["state"].crownDayState, weights: try input["weights"].array.map { try $0.halves }))
    }
    try RuleVectors.check("crown.json", "crownBankAmount") { FixtureValue(CrownDayState.bankAmount(try $0.array.map { try $0.crownDayState })) }
    try RuleVectors.check("crown.json", "recomputeCrownDay") { input in
      FixtureValue(ruleset.recomputeCrownDay(weights: try input["weights"].array.map { try $0.halves }, forfeited: try input["forfeited"].array.map { try $0.halves }))
    }
  }

  @Test("should anchor weekly crown periods on Monday and close them on Sunday")
  func crownPeriods() throws {
    try RuleVectors.check("crown.json", "crownPeriodOf") { input in
      let period = try #require(ruleset.crownPeriod(try input["cadence"].key(), containing: try Self.date(input["date"])))
      return .object(["cadence": .string(period.cadence.rawValue), "start": .string(period.start.isoString), "closesOn": .string(period.closesOn.isoString)])
    }
    try RuleVectors.check("crown.json", "isCrownPeriodClose") { .bool(ruleset.isCrownPeriodClose(try $0["cadence"].key(), on: try Self.date($0["date"]))) }
  }

  @Test("should report no weekly period that would leave the supported calendar")
  func crownPeriodEdges() throws {
    let first = try #require(LocalDate(year: 0, month: 1, day: 1))
    let last = try #require(LocalDate(year: 9999, month: 12, day: 31))
    #expect(ruleset.crownPeriod(.weekly, containing: first) == nil)
    #expect(ruleset.crownPeriod(.weekly, containing: last) == nil)
    #expect(ruleset.crownPeriod(.daily, containing: last)?.closesOn == last)
  }

  @Test("should arm, fire and pay the comeback as the reference does")
  func comeback() throws {
    try RuleVectors.check("comeback.json", "evaluateComebackArming") { FixtureValue(ruleset.comebackArming(for: try $0.comebackArmingInput)) }
    try RuleVectors.check("comeback.json", "comebackFireAllowance") { .int(ruleset.comebackFireAllowance(try $0.comebackDayState)) }
    try RuleVectors.check("comeback.json", "canFireComeback") { .bool(ruleset.canFireComeback(try $0["state"].comebackDayState, on: try $0["strictness"].key())) }
    try RuleVectors.check("comeback.json", "fireComeback") { input in
      let fire = ruleset.fireComeback(try input["state"].comebackDayState, on: try input["strictness"].key())
      return .object(["fired": .bool(fire.fired), "kind": .key(fire.kind), "state": FixtureValue(fire.state)])
    }
    try RuleVectors.check("comeback.json", "armComebackViaRecovery") { FixtureValue(try $0.comebackDayState.armedViaRecoveryQuest()) }
    try RuleVectors.check("comeback.json", "comebackBonus") { FixtureValue(ruleset.comebackBonus(claimed: try $0.rewardInput)) }
    try RuleVectors.check("comeback.json", "comebackNetXp") { .int(ruleset.comebackNetXP(forgone: try $0["forgone"].rewardInput, claimed: try $0["claimed"].rewardInput)) }
  }

  @Test("should fire the returner at its threshold and aim its shield at the longest pre-absence streak")
  func returner() throws {
    try RuleVectors.check("returner.json", "returnerThresholdFor") { .int(ruleset.returnerThreshold(try $0.optionalInt)) }
    try RuleVectors.check("returner.json", "returnerFires") { input in
      .bool(ruleset.returnerFires(daysSinceLastActivity: try input["daysSinceLastActivity"].int, thresholdDays: try input["thresholdDays"].optionalInt))
    }
    try RuleVectors.check("returner.json", "returnerShieldTarget") { input in
      guard let target = Ruleset.returnerShieldTarget(try Self.candidates(input)) else { return .null }
      return .object([
        "questId": .string(target.questID), "preAbsenceStreakDays": .int(target.preAbsenceStreakDays), "createdOrder": .int(target.createdOrder),
        "shields": .int(target.shields),
      ])
    }
    try RuleVectors.check("returner.json", "planReturnerShieldGrant") { input in
      let grant = ruleset.planReturnerShieldGrant(try Self.candidates(input))
      let placement =
        switch grant.placement {
        case .granted: "granted"
        case .heldPending: "held_pending"
        case .heldTargetless: "held_targetless"
        }
      return .object(["questId": grant.questID.map(FixtureValue.string) ?? .null, "shields": .int(grant.shields), "placement": .string(placement)])
    }
  }

  private static func date(_ value: FixtureValue) throws -> LocalDate {
    try #require(LocalDate(isoString: try value.string))
  }

  private static func candidates(_ value: FixtureValue) throws -> [ReturnerCandidate] {
    try value.array.map {
      ReturnerCandidate(
        questID: try $0["questId"].string, preAbsenceStreakDays: try $0["preAbsenceStreakDays"].int, createdOrder: try $0["createdOrder"].int,
        shields: try $0["shields"].int)
    }
  }
}
