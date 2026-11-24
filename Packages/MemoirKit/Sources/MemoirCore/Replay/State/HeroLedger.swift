import Foundation

/// The reference's `hero_event_type`.
public enum HeroEventType: String, RuleKey, Codable {
  case questComplete = "quest_complete"
  case questPartial = "quest_partial"
  case questLate = "quest_late"
  case recovery
  case levelUp = "level_up"
  case achievementUnlock = "achievement_unlock"
  case coinGrant = "coin_grant"
  case crownBanked = "crown_banked"
  case sideQuest = "side_quest"
  case journal
  case meal
  case weight
  case coinSpend = "coin_spend"
  case recoverySpawned = "recovery_spawned"
  case recoveryCompleted = "recovery_completed"
  case recoveryExpired = "recovery_expired"
  case crownInit = "crown_init"
  case crownForfeit = "crown_forfeit"
  case returnerFired = "returner_fired"
  case moneyFine = "money_fine"
  case moneyReward = "money_reward"
  case moneyLog = "money_log"
  case goalMilestone = "goal_milestone"
  case goalBought = "goal_bought"
}

/// One entry of the append-only hero trail; `key` is the reference's dedupe key, so the same action reached twice grants once.
public struct HeroEvent: Sendable, Hashable, Codable {
  public let key: String
  public let type: HeroEventType
  public let date: LocalDate
  public let xpDelta: Int
  public let coinsDelta: Int
  public let statAffinity: StatAffinity?
  public let statDelta: Int
  public let quest: UUID?
  public let log: UUID?
  public let state: QuestLogState?
  public let achievement: AchievementID?
  public let levelAfter: Int
  public let rulesetVersion: Int
}

/// A grant as `HeroLedger.grant` takes it.
struct GrantIntent: Sendable, Hashable {
  var key: String
  var type: HeroEventType
  var date: LocalDate
  var xpDelta = 0
  var coinsDelta = 0
  var statAffinity: StatAffinity?
  var statDelta = 0
  var quest: UUID?
  var log: UUID?
  var state: QuestLogState?
  var achievement: AchievementID?
  var levelAfter: Int?
}

enum GrantOutcome: Sendable, Hashable {
  case applied(HeroEvent)
  case duplicate(HeroEvent)

  var event: HeroEvent {
    switch self {
    case .applied(let event), .duplicate(let event): event
    }
  }

  var isApplied: Bool {
    guard case .applied = self else { return false }
    return true
  }
}

/// XP, level, coins and stats, moved only through `grant`, as the reference's `HeroLedger` is the single gate for every total.
public struct HeroLedger: Sendable, Hashable {
  public static let empty = HeroLedger()

  public internal(set) var totalXP = 0
  public internal(set) var level = 1
  public internal(set) var coins = 0
  public internal(set) var stats = RuleTable<StatAffinity, Int> { _ in 0 }
  public internal(set) var events: [HeroEvent] = []
  private var eventIndex: [String: Int] = [:]

  public func event(forKey key: String) -> HeroEvent? {
    eventIndex[key].map { events[$0] }
  }

  /// Applies each intent in turn, each seeing the totals the one before left, and appends a level-up event for every level an applied intent crosses.
  /// A spend beyond the balance refuses the whole grant (`HRO_001`) before anything changes, as the reference rolls back.
  mutating func grant(_ intents: [GrantIntent], ruleset: Ruleset) throws(ReplayRefusal) -> [GrantOutcome] {
    var balance = coins
    var keys = Set<String>()
    for intent in intents where event(forKey: intent.key) == nil && keys.insert(intent.key).inserted {
      let next = Exact.adding(balance, intent.coinsDelta)
      guard next >= 0 else { throw .notEnoughCoins(balance: balance, required: -intent.coinsDelta) }
      balance = next
    }
    return applyAll(intents, ruleset: ruleset)
  }

  /// A grant that spends nothing, so it can never be refused.
  mutating func credit(_ intents: [GrantIntent], ruleset: Ruleset) -> [GrantOutcome] {
    precondition(intents.allSatisfy { $0.coinsDelta >= 0 }, "a credit never spends coins")
    return applyAll(intents, ruleset: ruleset)
  }

  /// A coin fine takes at most the balance, so it is never refused, and its event records what it took; the coins it returns are that amount, or what
  /// the trail already holds for the key.
  mutating func fine(_ intent: GrantIntent, coins fine: Int, ruleset: Ruleset) -> Int {
    precondition(fine >= 0 && intent.coinsDelta == 0 && intent.xpDelta == 0, "a fine names its coins apart and moves nothing else")
    if let existing = event(forKey: intent.key) { return -existing.coinsDelta }
    var charged = intent
    charged.coinsDelta = -min(fine, coins)
    _ = applyAll([charged], ruleset: ruleset)
    return -charged.coinsDelta
  }

  private mutating func applyAll(_ intents: [GrantIntent], ruleset: Ruleset) -> [GrantOutcome] {
    var outcomes = [GrantOutcome]()
    for intent in intents {
      let levelBefore = level
      let outcome = apply(intent, ruleset: ruleset)
      outcomes.append(outcome)
      guard outcome.isApplied, level > levelBefore else { continue }
      for reached in (levelBefore + 1)...level {
        _ = apply(GrantIntent(key: "levelup_\(reached)", type: .levelUp, date: intent.date, levelAfter: reached), ruleset: ruleset)
      }
    }
    return outcomes
  }

  private mutating func apply(_ intent: GrantIntent, ruleset: Ruleset) -> GrantOutcome {
    if let existing = event(forKey: intent.key) { return .duplicate(existing) }
    let totalXP = Exact.adding(self.totalXP, intent.xpDelta)
    let level = ruleset.level.level(forTotalXP: totalXP)
    let event = HeroEvent(
      key: intent.key, type: intent.type, date: intent.date, xpDelta: intent.xpDelta, coinsDelta: intent.coinsDelta, statAffinity: intent.statAffinity,
      statDelta: intent.statDelta, quest: intent.quest, log: intent.log, state: intent.state, achievement: intent.achievement, levelAfter: intent.levelAfter ?? level,
      rulesetVersion: ruleset.version)
    self.totalXP = totalXP
    self.level = level
    coins = Exact.adding(coins, intent.coinsDelta)
    if let stat = intent.statAffinity { stats[stat] = Exact.adding(stats[stat], intent.statDelta) }
    eventIndex[intent.key] = events.count
    events.append(event)
    return .applied(event)
  }
}

/// The trail is the ledger: a decoded ledger's totals must be the sums of its events, and its key index is rebuilt from them.
extension HeroLedger: Codable {
  private enum CodingKeys: String, CodingKey {
    case totalXP
    case level
    case coins
    case stats
    case events
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var ledger = HeroLedger()
    ledger.totalXP = try container.decode(Int.self, forKey: .totalXP)
    ledger.level = try container.decode(Int.self, forKey: .level)
    ledger.coins = try container.decode(Int.self, forKey: .coins)
    ledger.stats = try container.decode(RuleTable<StatAffinity, Int>.self, forKey: .stats)
    ledger.events = try container.decode([HeroEvent].self, forKey: .events)
    for (index, event) in ledger.events.enumerated() {
      guard ledger.eventIndex.updateValue(index, forKey: event.key) == nil else {
        throw DecodingError.dataCorruptedError(forKey: .events, in: container, debugDescription: "The hero trail holds the key \(event.key) twice.")
      }
    }
    let stats = RuleTable<StatAffinity, Int> { stat in Exact.sum(ledger.events.filter { $0.statAffinity == stat }.map(\.statDelta)) }
    guard
      ledger.level >= 1, ledger.totalXP == Exact.sum(ledger.events.map(\.xpDelta)), ledger.coins == Exact.sum(ledger.events.map(\.coinsDelta)), ledger.coins >= 0,
      ledger.stats == stats
    else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "The hero's totals are not the sums of the trail."))
    }
    self = ledger
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(totalXP, forKey: .totalXP)
    try container.encode(level, forKey: .level)
    try container.encode(coins, forKey: .coins)
    try container.encode(stats, forKey: .stats)
    try container.encode(events, forKey: .events)
  }
}
