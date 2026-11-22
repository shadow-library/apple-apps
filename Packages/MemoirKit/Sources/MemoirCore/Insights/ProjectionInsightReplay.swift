import Foundation
import ShadowStore

/// The insight context's replay half, read from the derived rows the projection keeps and the main store's command notes, never by running replay. The
/// owner's notes and reflections are read only when `includingText` is set; the profile's zone is the clock in force now, the device's before any is set.
public struct ProjectionInsightReplay: InsightReplaySource {
  let main: VaultStore
  let now: @Sendable () -> Date
  let deviceZone: @Sendable () -> TimeZone

  public init(main: VaultStore, now: @escaping @Sendable () -> Date, deviceZone: @escaping @Sendable () -> TimeZone) {
    self.main = main
    self.now = now
    self.deviceZone = deviceZone
  }

  public func insightState(includingText: Bool) async throws(InsightError) -> InsightReplayState {
    let (now, device) = (now(), deviceZone())
    do {
      return try await main.read { transaction in try Self.state(in: transaction, includingText: includingText, now: now, device: device) }
    } catch {
      throw .replayUnavailable(error.code)
    }
  }

  static func state(in transaction: ReadTransaction, includingText: Bool, now: Date, device: TimeZone) throws(StoreError) -> InsightReplayState {
    let hero = try MemoirDerived.hero(in: transaction)
    let days = try MemoirDerived.days(in: transaction)
    let openDay = hero?.openDay
    let intensity = days.last { $0.date == openDay }?.intensityMode ?? .standard
    let zone = (hero?.zone ?? .unset).clock(at: now, device: device).timeZone.identifier
    func note(_ command: UUID?) throws(StoreError) -> String? {
      guard includingText, let command else { return nil }
      return try CommandNoteRecord.read(id: command, in: transaction).entry?.record.text
    }
    return InsightReplayState(
      profile: InsightProfile(timeZone: zone, intensityMode: intensity),
      quests: try MemoirDerived.quests(in: transaction).map(Self.quest),
      questLogs: try MemoirDerived.questLogs(in: transaction).map { row throws(StoreError) in
        let entry = row.entry
        return InsightQuestLog(
          quest: row.occurrence.quest, date: row.occurrence.date, state: entry.state, xpAwarded: entry.xpAwarded, coinsAwarded: entry.coinsAwarded,
          strictness: entry.strictness, intensityModeAtLog: entry.intensityModeAtLog, reasonTag: entry.reasonTag?.rawValue, rescheduledToMinutes: entry.rescheduledToMinute,
          postponedToDate: entry.postponedToDate, performedAtMillis: entry.performedAtMillis, reasonNote: try note(entry.reasonNote),
          reflectionText: try note(entry.reflection))
      },
      heroEvents: try MemoirDerived.heroEvents(in: transaction).map { row in
        let event = row.event
        return InsightHeroEvent(
          type: event.type.rawValue, quest: event.quest, state: event.state, xpDelta: event.xpDelta, coinsDelta: event.coinsDelta, statAffinity: event.statAffinity,
          statDelta: event.statDelta, levelAfter: event.levelAfter, achievement: event.achievement?.rawValue, date: event.date)
      },
      dailyStates: days.map(Self.day),
      progressionEvents: try progression(in: transaction, note: note))
  }

  private static func quest(_ row: QuestRow) -> InsightQuestState {
    let schedule = row.schedule
    return InsightQuestState(
      quest: row.id, startTimeMinutes: schedule.startTimeMinutes, durationMinutes: schedule.durationMinutes, statAffinity: schedule.statAffinity,
      strictness: schedule.strictness, recurrence: schedule.recurrence, active: schedule.active)
  }

  private static func day(_ row: DayRow) -> InsightDailyState {
    InsightDailyState(
      date: row.date, intensityMode: row.intensityMode, hpStart: row.hp?.hpStart, hpEnd: row.hp?.hpEnd, hpMax: row.hp?.hpMax, crownXPGranted: row.crownGranted?.xp ?? 0,
      crownBankedXP: row.crownBanked?.xp ?? 0, momentumBucket: row.momentum.rawValue, missedCount: row.missedCount)
  }

  private static func progression(in transaction: ReadTransaction, note: (UUID?) throws(StoreError) -> String?) throws(StoreError) -> [InsightProgressionEvent] {
    var events: [InsightProgressionEvent] = []
    for row in try MemoirDerived.recoveries(in: transaction) {
      let recovery = row.recovery
      events.append(
        .recoveryQuest(
          date: recovery.date, sourceQuest: recovery.sourceQuest, state: recovery.state, isReturnerDay: recovery.isReturnerDay,
          completedAtMillis: recovery.completedAtMillis, reflectionText: try note(recovery.reflection)))
    }
    for row in try MemoirDerived.comebacks(in: transaction) {
      events.append(.comeback(date: row.date, kind: row.kind.rawValue, xpBonus: row.xpBonus, coinBonus: row.coinBonus))
    }
    for row in try MemoirDerived.returners(in: transaction) {
      events.append(.returner(date: row.event.date, daysAbsent: row.event.daysAbsent, shieldPending: row.event.shieldPending))
    }
    for row in try MemoirDerived.shieldConsumptions(in: transaction) {
      events.append(.shieldConsumption(date: row.occurrence.date, quest: row.occurrence.quest))
    }
    for unlock in try MemoirDerived.unlocks(in: transaction) {
      guard let earned = unlock.unlockedOn else { continue }
      switch unlock.kind {
      case .achievement: events.append(.achievement(id: unlock.id, earnedOn: earned))
      case .title: events.append(.title(id: unlock.id, earnedOn: earned))
      case .cosmetic: continue
      }
    }
    return events
  }
}
