public struct HPBreak: Sendable, Hashable {
  /// One key per (quest, date) occurrence: a miss record and its break describe one occurrence and charge it once.
  public var occurrenceKey: String
  public var strictness: Strictness
  public var state: QuestLogState
  public var shielded: Bool
  public var streakDaysBefore: Int

  public init(occurrenceKey: String, strictness: Strictness, state: QuestLogState, shielded: Bool, streakDaysBefore: Int) {
    self.occurrenceKey = occurrenceKey
    self.strictness = strictness
    self.state = state
    self.shielded = shielded
    self.streakDaysBefore = streakDaysBefore
  }
}

public struct DayHP: Sendable, Hashable {
  public let hpStart: Int
  public let hpEnd: Int
  public let hpMax: Int
  public let spent: Int
}

extension Ruleset {
  public func hpMax(for mode: IntensityMode) -> Int {
    intensityModes[mode].hpMax
  }

  public func hpStart(for mode: IntensityMode, previousHPEnd: Int?) -> Int {
    let rules = intensityModes[mode]
    guard let previousHPEnd else { return rules.hpMax }
    return min(rules.hpMax, Exact.adding(max(0, previousHPEnd), rules.overnightHPRegen))
  }

  public func hpCost(of event: HPBreak, in mode: IntensityMode) -> Int {
    guard strictness[event.strictness].incursHPCost else { return 0 }
    guard [.missed, .skipped, .postponed].contains(event.state) else { return 0 }
    let cost = intensityModes[mode].hpCost
    let endsHighStreak = !event.shielded && streakTierMinDays(.silver).map { event.streakDaysBefore >= $0 } == true
    return endsHighStreak ? cost.perBreakEndingHighStreak : cost.perBreak
  }

  public func dayHP(in mode: IntensityMode, previousHPEnd: Int?, breaks: [HPBreak]) -> DayHP {
    let hpStart = hpStart(for: mode, previousHPEnd: previousHPEnd)
    let charged = breaks.reduce(into: [String: Int]()) { charged, event in
      charged[event.occurrenceKey] = max(charged[event.occurrenceKey] ?? 0, hpCost(of: event, in: mode))
    }
    let spent = Exact.sum(charged.values)
    return DayHP(hpStart: hpStart, hpEnd: max(0, Exact.subtracting(hpStart, spent)), hpMax: hpMax(for: mode), spent: spent)
  }
}

extension IntensityMode {
  public func indicatesLowEnergy(missesToday: Int) -> Bool {
    self != .lowIntensity && missesToday >= 2
  }
}
