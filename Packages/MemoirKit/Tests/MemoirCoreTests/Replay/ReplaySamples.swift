import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import MemoirCore

/// Three daily quests and the commands devices issue against them, shared by the replay and projection convergence tests; money bodies (ruleset v2) mix
/// with the rest, which devices stamp with v1 or v2.
enum ReplaySamples {
  static let quests = (1...3).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-00000000c%03d", $0)) }
  static let budgets = (1...2).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-00000000b%03d", $0)) }
  static let goals = (1...2).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-00000000d%03d", $0)) }
  static let firstDay = 20_517
  static let idEpoch = Date(timeIntervalSince1970: 1_700_000_000)
  static let millisPerDay: Int64 = 86_400_000

  static func schedules() throws -> [QuestSchedule] {
    let recurrence = try RecurrenceRule(frequency: .daily, startDate: try MemoirStoreFixture.date("2026-03-01"))
    return [
      try QuestSchedule(strictness: .anchor, startTimeMinutes: 420, durationMinutes: 30, statAffinity: .discipline, recurrence: recurrence),
      try QuestSchedule(strictness: .routine, startTimeMinutes: 480, durationMinutes: 60, statAffinity: .body, recurrence: recurrence),
      try QuestSchedule(strictness: .goal, statAffinity: .wealth, recurrence: recurrence),
    ]
  }

  /// A command some device could issue on its own day: a quest action (today's or an offline one for the days before), a log edit, a quick log, a purchase,
  /// a setting, a lock, a Recovery completion, or money logging, a period close or a goal reward, which repeat keys so that duplicates race.
  static func randomBody(on day: LocalDate, using generator: inout SeededGenerator) throws -> MemoirCommandBody {
    let occurrence = Occurrence(quest: generator.pick(from: quests), date: try #require(day.adding(days: -generator.int(in: 0...2))))
    let tag = generator.chance(0.5) ? generator.pick(from: ReasonTag.allCases) : nil
    switch generator.int(in: 0...21) {
    case 16, 17: return .moneyNoSpend(NoSpendDay(date: try #require(day.adding(days: -generator.int(in: 0...3)))))
    case 18: return .expenseCreate(ExpenseCreation(id: UUID.v7(at: idEpoch, using: &generator), occurredOn: try #require(day.adding(days: -generator.int(in: 0...3)))))
    case 19:
      let outcome = generator.pick(from: BudgetCloseOutcome.allCases)
      let deposits = (outcome == .within || outcome == .withinTypical) && generator.chance(0.5)
      let periodStart = try #require(LocalDate(daysSinceEpoch: firstDay - 30 * generator.int(in: 1...2)))
      return .budgetClosePeriod(try BudgetPeriodClose(budgetId: generator.pick(from: budgets), periodStart: periodStart, outcome: outcome, deposited: deposits))
    case 20: return .goalMilestone(GoalMilestoneReached(goalId: generator.pick(from: goals), milestone: generator.pick(from: GoalMilestone.allCases)))
    case 21: return .goalBought(GoalPurchase(goalId: generator.pick(from: goals), outcome: generator.pick(from: GoalPurchaseOutcome.allCases)))
    case 0, 1, 2: return .questComplete(occurrence)
    case 3: return .questPartial(occurrence)
    case 4: return .questSkip(QuestBreak(occurrence: occurrence, reasonTag: tag))
    case 5: return .questPostpone(QuestBreak(occurrence: occurrence, reasonTag: tag))
    case 6:
      return .questReschedule(
        try QuestReschedule(occurrence: occurrence, toMinute: generator.int(in: 0...1_439), acceptBeyondCap: generator.chance(0.5), reasonTag: tag))
    case 7: return .questAttachReason(try QuestReason(occurrence: occurrence, reasonTag: tag ?? .other, hasNote: false))
    case 8: return .questDeleteLog(occurrence)
    case 9: return .journalSave(QuickLogEntry(id: UUID.v7(at: idEpoch, using: &generator), date: day))
    case 10: return .sideQuestLog(SideQuestEntry(id: UUID.v7(at: idEpoch, using: &generator), date: day, statAffinity: generator.pick(from: StatAffinity.allCases)))
    case 11: return .cosmeticPurchase(generator.pick(from: [CosmeticID.badgeBronze, .themeSunrise, .themeMidnight]))
    case 12: return .accountSetIntensityMode(IntensityModeChange(mode: generator.pick(from: IntensityMode.allCases)))
    case 13, 14: return generator.chance(0.8) ? .planSetLock(try PlanLock(locking: Array(generator.shuffled(quests).prefix(generator.int(in: 1...3))))) : .planSetLock(.unlocked)
    default: return .recoveryComplete(RecoveryCompletion())
    }
  }

  /// A body that needs money rules is stamped v2; any other is stamped v1 or v2, as an older and a newer device would.
  static func command(_ body: MemoirCommandBody, at instant: Int64, offset: Int, using generator: inout SeededGenerator) throws -> MemoirCommand {
    let version = body.minimumRulesetVersion > Ruleset.v1.version || generator.chance(0.5) ? Ruleset.v2.version : Ruleset.v1.version
    return try MemoirCommand(
      id: UUID.v7(at: idEpoch, using: &generator), body: body, instantMillis: instant, utcOffsetMinutes: offset,
      issuedOn: try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: offset), rulesetVersion: version)
  }
}
