import Foundation
import ShadowStore

/// The Crown period containing a day, as far as it has run: `modules/progression/hero-standing.service.ts:64-77`.
public struct CrownWindow: Sendable, Hashable {
  public let cadence: CrownCadence
  public let periodStart: LocalDate
  public let closesOn: LocalDate
  /// 1 on the period's first day.
  public let dayIndex: Int
  public let dayCount: Int
  public let granted: RewardAmount
  public let remaining: RewardAmount
  /// The share of the granted XP still standing, rounded half up; 100 when nothing was granted.
  public let keptPercent: Int

  static func load(containing date: LocalDate, row: DayRow?, ruleset: Ruleset, in transaction: ReadTransaction) throws(StoreError) -> CrownWindow? {
    guard let row, let period = ruleset.crownPeriod(ruleset.crownCadence(for: row.intensityMode), containing: date) else { return nil }
    let days = try MemoirDerived.days(from: period.start, through: date, in: transaction).filter { $0.crownPeriodStart == period.start }
    let granted = RewardAmount(xp: Exact.sum(days.map { $0.crownGranted?.xp ?? 0 }), coins: Exact.sum(days.map { $0.crownGranted?.coins ?? 0 }))
    let remaining = RewardAmount(xp: Exact.sum(days.map { $0.crownRemaining?.xp ?? 0 }), coins: Exact.sum(days.map { $0.crownRemaining?.coins ?? 0 }))
    let kept = granted.xp == 0 ? 100 : Int(clamping: Exact.roundHalfUp(Int128(remaining.xp) * 100, Int128(granted.xp)))
    return CrownWindow(
      cadence: period.cadence, periodStart: period.start, closesOn: period.closesOn, dayIndex: date.days(since: period.start) + 1,
      dayCount: period.closesOn.days(since: period.start) + 1, granted: granted, remaining: remaining, keptPercent: kept)
  }
}

/// A day's Comeback: armed by recent misses, it fires on the next anchor or routine quest kept, up to its allowance.
public struct ComebackStanding: Sendable, Hashable {
  public let armed: Bool
  public let fires: Int
  public let allowance: Int
  public let viaRecovery: Bool

  public var claimed: Bool { fires > 0 }

  init(_ row: DayRow, ruleset: Ruleset) {
    armed = row.comebackArmed
    fires = row.comebackFires
    viaRecovery = row.comebackViaRecovery
    allowance = ruleset.comebackFireAllowance(ComebackDayState(armed: row.comebackArmed, fires: row.comebackFires, armedViaRecovery: row.comebackViaRecovery))
  }
}

/// Why the open day frames a return (`hero-standing.service.ts:79-88`, `synced-hero-provider.ts:156-159`): the Returner ritual outranks a Recovery
/// quest the same return spawned, and a Comeback armed or claimed today comes last.
public enum ComingBackReason: String, Sendable, Hashable {
  case returner
  case recovery
  case comeback

  static func on(_ row: DayRow?, recovery: RecoveryRow?) -> ComingBackReason? {
    guard let row else { return nil }
    if row.returnerFired { return .returner }
    if recovery?.recovery.state == .pending { return .recovery }
    return row.comebackArmed || row.comebackFires > 0 ? .comeback : nil
  }
}

/// The shields the active quests hold: a quest outside streak eligibility counts toward the cap only while it holds one
/// (`hero-standing.service.ts:55-59`).
public struct ShieldStanding: Sendable, Hashable {
  public let available: Int
  public let cap: Int

  init(available: Int, cap: Int) {
    self.available = available
    self.cap = cap
  }

  init(_ quests: [QuestRow], ruleset: Ruleset) {
    let counted = quests.filter { quest in
      quest.schedule.active && (quest.streak.shields > 0 || ruleset.streakApplies(to: quest.schedule.strictness, optIn: quest.schedule.optionalStreakOptIn))
    }
    available = Exact.sum(counted.map(\.streak.shields))
    cap = counted.count * ruleset.shields.capPerQuest
  }
}

/// The hero's level and how far into it: `hero-standing.service.ts:51-53`. `xpForNextLevel` is 0 at the highest level.
public struct LevelProgress: Sendable, Hashable {
  public let level: Int
  public let totalXP: Int
  public let xpIntoLevel: Int
  public let xpForNextLevel: Int

  public var isHighestLevel: Bool { xpForNextLevel == 0 }

  init(level: Int, totalXP: Int, ruleset: Ruleset) {
    self.level = level
    self.totalXP = totalXP
    xpIntoLevel = max(0, Exact.subtracting(totalXP, ruleset.level.xpThreshold(forLevel: level)))
    xpForNextLevel = ruleset.level.xpToAdvance(fromLevel: level)
  }
}
