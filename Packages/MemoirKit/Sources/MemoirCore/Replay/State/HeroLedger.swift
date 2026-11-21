import Foundation

/// The reference's `hero_event_type`.
public enum HeroEventType: String, RuleKey {
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
}

/// One entry of the append-only hero trail; `key` is the reference's dedupe key, so the same action reached twice grants once.
public struct HeroEvent: Sendable, Hashable {
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
