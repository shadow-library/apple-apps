/// Replay checkpoints persist the rule states between days, so each decodes only what the current ruleset can produce; a checkpoint written under
/// another ruleset is rebuilt by replay rather than read.
extension StreakState: Codable {
  private enum CodingKeys: String, CodingKey {
    case currentDays
    case longestDays
    case shields
    case completionsTowardShield
    case pendingShieldGrant
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state = StreakState(
      currentDays: try container.decode(Int.self, forKey: .currentDays), longestDays: try container.decode(Int.self, forKey: .longestDays),
      shields: try container.decode(Int.self, forKey: .shields), completionsTowardShield: try container.decode(Int.self, forKey: .completionsTowardShield),
      pendingShieldGrant: try container.decode(Int.self, forKey: .pendingShieldGrant))
    let counts = [state.currentDays, state.longestDays, state.shields, state.completionsTowardShield, state.pendingShieldGrant]
    guard counts.allSatisfy({ $0 >= 0 }), state.longestDays >= state.currentDays else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "A streak holds non-negative counts and its longest run is at least its current one."))
    }
    self = state
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(currentDays, forKey: .currentDays)
    try container.encode(longestDays, forKey: .longestDays)
    try container.encode(shields, forKey: .shields)
    try container.encode(completionsTowardShield, forKey: .completionsTowardShield)
    try container.encode(pendingShieldGrant, forKey: .pendingShieldGrant)
  }
}

extension ComebackDayState: Codable {
  private enum CodingKeys: String, CodingKey {
    case armed
    case fires
    case armedViaRecovery
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state = ComebackDayState(
      armed: try container.decode(Bool.self, forKey: .armed), fires: try container.decode(Int.self, forKey: .fires),
      armedViaRecovery: try container.decode(Bool.self, forKey: .armedViaRecovery))
    guard (0...Ruleset.current.comebackFireAllowance(state)).contains(state.fires) else {
      throw DecodingError.dataCorruptedError(forKey: .fires, in: container, debugDescription: "A day fires Comeback at most as often as the ruleset allows.")
    }
    self = state
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(armed, forKey: .armed)
    try container.encode(fires, forKey: .fires)
    try container.encode(armedViaRecovery, forKey: .armedViaRecovery)
  }
}

extension CrownDayState: Codable {
  /// Nil unless the forfeit stays within the endowment and each remainder within what was granted, as the Crown rules keep them.
  public init?(endowed: Halves, forfeited: Halves, granted: RewardAmount, remaining: RewardAmount) {
    guard forfeited.halves >= 0, forfeited <= endowed, granted.xp >= 0, granted.coins >= 0, (0...granted.xp).contains(remaining.xp), (0...granted.coins).contains(remaining.coins)
    else {
      return nil
    }
    self.init(
      endowedWeight: endowed, forfeitedWeight: forfeited, grantedXP: granted.xp, grantedCoins: granted.coins, remainingXP: remaining.xp, remainingCoins: remaining.coins)
  }

  private enum CodingKeys: String, CodingKey {
    case endowedHalves
    case forfeitedHalves
    case grantedXP
    case grantedCoins
    case remainingXP
    case remainingCoins
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let state = CrownDayState(
        endowed: Halves(try container.decode(Int.self, forKey: .endowedHalves)), forfeited: Halves(try container.decode(Int.self, forKey: .forfeitedHalves)),
        granted: RewardAmount(xp: try container.decode(Int.self, forKey: .grantedXP), coins: try container.decode(Int.self, forKey: .grantedCoins)),
        remaining: RewardAmount(xp: try container.decode(Int.self, forKey: .remainingXP), coins: try container.decode(Int.self, forKey: .remainingCoins)))
    else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A Crown day forfeits at most its endowment and keeps at most what it granted."))
    }
    self = state
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(endowedWeight.halves, forKey: .endowedHalves)
    try container.encode(forfeitedWeight.halves, forKey: .forfeitedHalves)
    try container.encode(grantedXP, forKey: .grantedXP)
    try container.encode(grantedCoins, forKey: .grantedCoins)
    try container.encode(remainingXP, forKey: .remainingXP)
    try container.encode(remainingCoins, forKey: .remainingCoins)
  }
}

extension ProgressCounters: Codable {
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case totalXP
    case level
    case stats
    case questsCompleted
    case completionsByStrictness
    case longestStreakDays
    case longestAnchorStreakDays
    case questsReachingSilverStreak
    case subscriptionsConfirmed
    case receiptsScanned
    case fullHPDays
    case crownsBanked
    case lockedDaysCleared
    case comebackBonusesClaimed
    case returnerRitualsCompleted
    case completionsAfterReturner
    case reschedulesWithReasonIn90Days
    case reasonTaggedEvents
    case activeDays
  }

  private static var counts: [(CodingKeys, WritableKeyPath<ProgressCounters, Int>)] {
    [
      (.totalXP, \.totalXP), (.level, \.level), (.questsCompleted, \.questsCompleted), (.longestStreakDays, \.longestStreakDays),
      (.longestAnchorStreakDays, \.longestAnchorStreakDays), (.questsReachingSilverStreak, \.questsReachingSilverStreak),
      (.subscriptionsConfirmed, \.subscriptionsConfirmed), (.receiptsScanned, \.receiptsScanned), (.fullHPDays, \.fullHPDays), (.crownsBanked, \.crownsBanked),
      (.lockedDaysCleared, \.lockedDaysCleared), (.comebackBonusesClaimed, \.comebackBonusesClaimed), (.returnerRitualsCompleted, \.returnerRitualsCompleted),
      (.completionsAfterReturner, \.completionsAfterReturner), (.reschedulesWithReasonIn90Days, \.reschedulesWithReasonIn90Days),
      (.reasonTaggedEvents, \.reasonTaggedEvents), (.activeDays, \.activeDays),
    ]
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var counters = ProgressCounters()
    for (key, path) in Self.counts {
      let value = try container.decode(Int.self, forKey: key)
      guard value >= 0 else { throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Progress counters are never negative.") }
      counters[keyPath: path] = value
    }
    guard counters.level >= 1 else { throw DecodingError.dataCorruptedError(forKey: .level, in: container, debugDescription: "Levels start at 1.") }
    counters.stats = try container.decode(RuleTable<StatAffinity, Int>.self, forKey: .stats)
    counters.completionsByStrictness = try container.decode(RuleTable<Strictness, Int>.self, forKey: .completionsByStrictness)
    let tables = counters.stats.entries.map(\.value) + counters.completionsByStrictness.entries.map(\.value)
    guard tables.allSatisfy({ $0 >= 0 }) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Progress counters are never negative."))
    }
    self = counters
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    for (key, path) in Self.counts { try container.encode(self[keyPath: path], forKey: key) }
    try container.encode(stats, forKey: .stats)
    try container.encode(completionsByStrictness, forKey: .completionsByStrictness)
  }
}

extension RuleTable: Decodable where Value: Decodable {
  /// Every key of the table must be present, so a table never decodes with a value made up for a missing key.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: RawKey.self)
    var values = [Key: Value]()
    for key in Key.allCases { values[key] = try container.decode(Value.self, forKey: RawKey(key.rawValue)) }
    self.init { key in
      guard let value = values[key] else { preconditionFailure("every key was decoded above") }
      return value
    }
  }
}

extension AchievementID: Codable, CodingKeyRepresentable {}

extension TitleID: Codable, CodingKeyRepresentable {}

extension CosmeticID: Codable, CodingKeyRepresentable {}

extension Halves: Decodable {
  private enum DecodingKeys: String, CodingKey {
    case halves
  }

  public init(from decoder: any Decoder) throws {
    self.init(try decoder.container(keyedBy: DecodingKeys.self).decode(Int.self, forKey: .halves))
  }
}

extension Thousandths: Decodable {
  private enum DecodingKeys: String, CodingKey {
    case thousandths
  }

  public init(from decoder: any Decoder) throws {
    self.init(try decoder.container(keyedBy: DecodingKeys.self).decode(Int.self, forKey: .thousandths))
  }
}

extension RewardAmount: Codable {
  private enum CodingKeys: String, CodingKey {
    case xp
    case coins
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let amount = RewardAmount(xp: try container.decode(Int.self, forKey: .xp), coins: try container.decode(Int.self, forKey: .coins))
    guard amount.xp >= 0, amount.coins >= 0 else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A reward grants no negative XP or coins."))
    }
    self = amount
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(xp, forKey: .xp)
    try container.encode(coins, forKey: .coins)
  }
}

extension DayHP: Codable {
  private enum CodingKeys: String, CodingKey {
    case hpStart
    case hpEnd
    case hpMax
    case spent
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let hp = DayHP(
      hpStart: try container.decode(Int.self, forKey: .hpStart), hpEnd: try container.decode(Int.self, forKey: .hpEnd),
      hpMax: try container.decode(Int.self, forKey: .hpMax), spent: try container.decode(Int.self, forKey: .spent))
    guard hp.spent >= 0, (0...hp.hpMax).contains(hp.hpStart), (0...hp.hpStart).contains(hp.hpEnd) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A day's HP stays within its maximum and only falls."))
    }
    self = hp
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hpStart, forKey: .hpStart)
    try container.encode(hpEnd, forKey: .hpEnd)
    try container.encode(hpMax, forKey: .hpMax)
    try container.encode(spent, forKey: .spent)
  }
}

extension ComebackTrigger: Decodable {
  private enum Kind: String, Decodable {
    case anchorMissYesterday = "anchor_miss_yesterday"
    case missWithinDays = "miss_within_days"
  }

  private enum DecodingKeys: String, CodingKey {
    case kind
    case days
    case strictness
    case requiresColdMomentum
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: DecodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .anchorMissYesterday:
      self = .anchorMissYesterday
    case .missWithinDays:
      self = .missWithinDays(
        days: try container.decode(Int.self, forKey: .days), strictness: try container.decode([Strictness].self, forKey: .strictness),
        requiresColdMomentum: try container.decode(Bool.self, forKey: .requiresColdMomentum))
    }
  }
}
