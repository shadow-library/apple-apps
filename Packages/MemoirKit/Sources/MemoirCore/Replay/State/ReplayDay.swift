import Foundation

/// The plan lock of one day: `plan.setLock` commits it on the open day and a postpone of a locked quest breaks it.
public struct DayLock: Sendable, Hashable, Codable {
  public let committedAtMillis: Int64
  public let quests: [UUID]
  public internal(set) var brokenAtMillis: Int64?

  public var isActive: Bool { brokenAtMillis == nil }
}

public enum ComebackEventKind: String, RuleKey, Codable, CodingKeyRepresentable {
  case armed
  case reArmed = "re_armed"
  case fired
  case reFired = "re_fired"
}

/// The reference's `comebackEvents` row, one per day and kind.
public struct ComebackEvent: Sendable, Hashable, Codable {
  public let kind: ComebackEventKind
  public let trigger: ComebackTrigger?
  public let sourceLog: UUID?
  public let consumedLog: UUID?
  public let xpBonus: Int
  public let coinBonus: Int
  public let intensityMode: IntensityMode
}

public struct DayCrown: Sendable, Hashable, Codable {
  public internal(set) var state: CrownDayState
  public internal(set) var periodStart: LocalDate
  public internal(set) var banked: RewardAmount?
}

/// One day's `daily_states` row. The day walk opens and closes days; commands only touch the open ones.
public struct ReplayDay: Sendable, Hashable, Codable {
  public let date: LocalDate
  public internal(set) var intensityMode: IntensityMode
  public internal(set) var rulesetVersion: Int
  public internal(set) var hp: DayHP?
  public internal(set) var crown: DayCrown?
  public internal(set) var lock: DayLock?
  public internal(set) var comeback: ComebackDayState
  public internal(set) var comebackFiredAtMillis: Int64?
  public internal(set) var comebackEvents: [ComebackEventKind: ComebackEvent]
  public internal(set) var returnerActive: Bool
  public internal(set) var returnerFired: Bool
  public internal(set) var momentum: MomentumBucket
  public internal(set) var missedCount: Int
  public internal(set) var isClosed: Bool

  init(
    date: LocalDate, intensityMode: IntensityMode, rulesetVersion: Int, comeback: ComebackDayState = .empty, momentum: MomentumBucket = .steady,
    returnerActive: Bool = false, returnerFired: Bool = false
  ) {
    self.date = date
    self.intensityMode = intensityMode
    self.rulesetVersion = rulesetVersion
    self.comeback = comeback
    self.comebackEvents = [:]
    self.returnerActive = returnerActive
    self.returnerFired = returnerFired
    self.momentum = momentum
    self.missedCount = 0
    self.isClosed = false
  }

  public var isOpen: Bool { !isClosed }

  public func lockBonusApplies(to quest: UUID) -> Bool {
    guard let lock, lock.isActive else { return false }
    return lock.quests.contains(quest)
  }

  /// `false` when the day already recorded an event of this kind, as the natural key `(date, kind)` refuses a second.
  @discardableResult
  mutating func record(_ event: ComebackEvent) -> Bool {
    guard comebackEvents[event.kind] == nil else { return false }
    comebackEvents[event.kind] = event
    return true
  }
}
