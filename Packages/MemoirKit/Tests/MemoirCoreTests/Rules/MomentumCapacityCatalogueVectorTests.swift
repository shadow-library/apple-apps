import MemoirCore
import Testing

@Suite("Momentum, capacity and catalogue vectors", TestTimeLimit.standard)
struct MomentumCapacityCatalogueVectorTests {
  private let ruleset = Ruleset.v1

  @Test("should take medians as exact halves")
  func medians() throws {
    try RuleVectors.check("momentum.json", "medianOf") { .fraction(Halves.median(of: try $0.array.map { try $0.int }).fraction) }
    try RuleVectors.check("momentum.json", "trailingMedian") { input in
      .fraction(Halves.trailingMedian(of: try input["values"].array.map { try $0.int }, windowDays: try input["windowDays"].int).fraction)
    }
  }

  @Test("should weigh momentum in tenths and bucket it by exact ratio")
  func momentum() throws {
    try RuleVectors.check("momentum.json", "computeMomentum") { input in
      FixtureValue(
        ruleset.momentum(
          for: MomentumInput(
            recentCompletions: try input["recentCompletions"].array.map { try $0.int },
            trailingCompletions: try input["trailingCompletions"].array.map { try $0.int })))
    }
  }

  @Test("should read steady where the reference's float reads cold at exactly the cold ratio")
  func momentumAtTheColdRatio() {
    let momentum = ruleset.momentum(for: MomentumInput(recentCompletions: [0, 3, 0], trailingCompletions: Array(repeating: 7, count: 14)))
    #expect(momentum.weighted == Tenths(21))
    #expect(momentum.ratio == Fraction(numerator: 3, denominator: 10))
    #expect(momentum.bucket == .steady)
  }

  @Test("should ratchet capacity and warn as the reference does")
  func capacity() throws {
    try RuleVectors.check("capacity.json", "computeCapacity") { input in
      let capacity = ruleset.capacity(
        for: CapacityInput(
          trailingCompletions: try input["trailingCompletions"].array.map { try $0.int }, momentum: try input["momentum"].key(),
          priorDayHeavyMiss: try input["priorDayHeavyMiss"].bool))
      return .object(["baseline": .fraction(capacity.baseline), "capacity": .int(capacity.capacity)])
    }
    try RuleVectors.check("capacity.json", "capacityWarningFor") { input in
      let warning = ruleset.capacityWarning(
        for: CapacityWarningInput(
          plannedLoad: try input["plannedLoad"].int, capacity: try input["capacity"].int, onLockAttempt: try input["onLockAttempt"].bool,
          daysSinceLastSoftWarning: try input["daysSinceLastSoftWarning"].optionalInt))
      return .string(warning.rawValue)
    }
    try RuleVectors.check("capacity.json", "anchorSoftCapWarned") { .bool(ruleset.anchorSoftCapWarned(existingAnchorCount: try $0.int)) }
  }

  @Test("should hold the reference catalogues in their order")
  func catalogues() throws {
    try RuleVectors.check("catalogue.json", "achievementIds") { _ in .keys(AchievementID.allCases) }
    try RuleVectors.check("catalogue.json", "titleIds") { _ in .keys(TitleID.allCases) }
  }

  @Test("should grant achievements and titles at each threshold and not one below it")
  func thresholds() throws {
    try RuleVectors.check("catalogue.json", "satisfiedAchievements") { .keys(ruleset.satisfiedAchievements(try $0.progressCounters)) }
    try RuleVectors.check("catalogue.json", "satisfiedTitles") { .keys(ruleset.satisfiedTitles(try $0.progressCounters)) }
    try RuleVectors.check("catalogue.json", "unlockedAchievements") { input in
      .keys(ruleset.unlockedAchievements(try input["counters"].progressCounters, earned: try input["earned"].array.compactMap { AchievementID(rawValue: try $0.string) }))
    }
    try RuleVectors.check("catalogue.json", "unlockedTitles") { input in
      .keys(ruleset.unlockedTitles(try input["counters"].progressCounters, earned: try input["earned"].array.compactMap { TitleID(rawValue: try $0.string) }))
    }
    try RuleVectors.check("catalogue.json", "recomputeAchievements") { .keys(ruleset.recomputeAchievements(try $0.array.map { try $0.progressCounters })) }
    try RuleVectors.check("catalogue.json", "recomputeTitles") { .keys(ruleset.recomputeTitles(try $0.array.map { try $0.progressCounters })) }
  }
}
