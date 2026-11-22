import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

/// What the insight context should read, mapped straight from a full replay as the test stub hands it, so the projection's reading can be held to it.
enum ReplayInsightReference {
  static func state(_ state: ReplayState, notes: [UUID: String], includingText: Bool, now: Date, device: TimeZone) -> InsightReplayState {
    let note = { (id: UUID?) in includingText ? id.flatMap { notes[$0] } : nil }
    let openDay = state.openDay.flatMap { state.days[$0] }
    let quests = state.quests.values.map { quest in
      InsightQuestState(
        quest: quest.id, startTimeMinutes: quest.schedule.startTimeMinutes, durationMinutes: quest.schedule.durationMinutes, statAffinity: quest.schedule.statAffinity,
        strictness: quest.schedule.strictness, recurrence: quest.schedule.recurrence, active: quest.schedule.active)
    }
    let logs = state.logs.all.map { log in
      let entry = log.value
      return InsightQuestLog(
        quest: log.occurrence.quest, date: log.occurrence.date, state: entry.state, xpAwarded: entry.xpAwarded, coinsAwarded: entry.coinsAwarded,
        strictness: entry.strictness, intensityModeAtLog: entry.intensityModeAtLog, reasonTag: entry.reasonTag?.rawValue, rescheduledToMinutes: entry.rescheduledToMinute,
        postponedToDate: entry.postponedToDate, performedAtMillis: entry.performedAtMillis, reasonNote: note(entry.reasonNote), reflectionText: note(entry.reflection))
    }
    let events = state.hero.events.map { event in
      InsightHeroEvent(
        type: event.type.rawValue, quest: event.quest, state: event.state, xpDelta: event.xpDelta, coinsDelta: event.coinsDelta, statAffinity: event.statAffinity,
        statDelta: event.statDelta, levelAfter: event.levelAfter, achievement: event.achievement?.rawValue, date: event.date)
    }
    let days = state.days.values.map { day in
      InsightDailyState(
        date: day.date, intensityMode: day.intensityMode, hpStart: day.hp?.hpStart, hpEnd: day.hp?.hpEnd, hpMax: day.hp?.hpMax,
        crownXPGranted: day.crown?.state.grantedXP ?? 0, crownBankedXP: day.crown?.banked?.xp ?? 0, momentumBucket: day.momentum.rawValue, missedCount: day.missedCount)
    }
    var progression: [InsightProgressionEvent] = state.compassion.recoveries.values.map { recovery in
      .recoveryQuest(
        date: recovery.date, sourceQuest: recovery.sourceQuest, state: recovery.state, isReturnerDay: recovery.isReturnerDay, completedAtMillis: recovery.completedAtMillis,
        reflectionText: note(recovery.reflection))
    }
    progression += state.days.values.flatMap { day in
      day.comebackEvents.values.map { InsightProgressionEvent.comeback(date: day.date, kind: $0.kind.rawValue, xpBonus: $0.xpBonus, coinBonus: $0.coinBonus) }
    }
    progression += state.compassion.returnerEvents.values.map { .returner(date: $0.date, daysAbsent: $0.daysAbsent, shieldPending: $0.shieldPending) }
    progression += state.shieldConsumptions.map { .shieldConsumption(date: $0.date, quest: $0.quest) }
    progression += state.progression.achievements.map { .achievement(id: $0.key.rawValue, earnedOn: $0.value) }
    progression += state.progression.titles.map { .title(id: $0.key.rawValue, earnedOn: $0.value) }
    let zone = AccountZone(state).clock(at: now, device: device).timeZone.identifier
    return InsightReplayState(
      profile: InsightProfile(timeZone: zone, intensityMode: openDay?.intensityMode ?? .standard), quests: quests, questLogs: logs, heroEvents: events,
      dailyStates: days, progressionEvents: progression
    ).normalized
  }
}

extension InsightReplayState {
  /// Each list in a fixed order, since neither side promises one.
  var normalized: InsightReplayState {
    func sorted<Item>(_ items: [Item]) -> [Item] { items.sorted { String(describing: $0) < String(describing: $1) } }
    return InsightReplayState(
      profile: profile, quests: sorted(quests), questLogs: sorted(questLogs), heroEvents: sorted(heroEvents), dailyStates: sorted(dailyStates),
      progressionEvents: sorted(progressionEvents))
  }
}

@Suite("Projection insight replay", TestTimeLimit.property)
struct ProjectionInsightReplayTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let device = TimeZone(identifier: "Asia/Tokyo")!

  private func source(_ device: ReadsDevice) -> ProjectionInsightReplay {
    ProjectionInsightReplay(main: device.store, now: { Self.now }, deviceZone: { Self.device })
  }

  private func expected(_ device: ReadsDevice, through day: LocalDate, minute: Int, includingText: Bool) async throws -> InsightReplayState {
    let (commands, notes) = try await device.store.read { transaction in
      (try Replay.commands(in: transaction), try CommandNoteRecord.listing(in: transaction).entries.map(\.record))
    }
    let state = Replay.run(commands, through: ReadsDevice.stamp(day, minute: minute))
    let texts = Dictionary(uniqueKeysWithValues: notes.map { ($0.command, $0.text) })
    return ReplayInsightReference.state(state, notes: texts, includingText: includingText, now: Self.now, device: Self.device)
  }

  @Test func shouldReadWhatAFullReplayHoldsOnRandomHistories() async throws {
    var totals = (events: 0, recoveries: 0, shields: 0, comebacks: 0, returners: 0, achievements: 0, days: 0, logs: 0)
    try await forAll(iterations: 10) { generator in
      let device = try ReadsDevice()
      let created = Int64(ReplaySamples.firstDay - 1) * ReplaySamples.millisPerDay + 6 * 3_600_000
      var history = try zip(ReplaySamples.quests, try ReplaySamples.schedules()).map { quest, schedule in
        try ReplaySamples.command(.questCreate(QuestCreation(questId: quest, schedule: schedule)), at: created, offset: 0, using: &generator)
      }
      let days = generator.int(in: 4...24)
      for index in 0..<days {
        let day = try #require(LocalDate(daysSinceEpoch: ReplaySamples.firstDay + index))
        for minute in (0..<generator.int(in: 0...5)).map({ _ in generator.int(in: 360...1_380) }).sorted() {
          let instant = Int64(day.daysSinceEpoch) * ReplaySamples.millisPerDay + Int64(minute) * 60_000
          history.append(try ReplaySamples.command(try ReplaySamples.randomBody(on: day, using: &generator), at: instant, offset: 0, using: &generator))
        }
      }
      try await device.append(history)
      let openDay = try #require(LocalDate(daysSinceEpoch: ReplaySamples.firstDay + days - 1))
      try await device.walk(to: openDay, minute: 1_400)

      let read = try await source(device).insightState(includingText: false).normalized
      #expect(read == (try await expected(device, through: openDay, minute: 1_400, includingText: false)))
      totals.events += read.heroEvents.count
      totals.recoveries += read.progressionEvents.count { if case .recoveryQuest = $0 { true } else { false } }
      totals.shields += read.progressionEvents.count { if case .shieldConsumption = $0 { true } else { false } }
      totals.comebacks += read.progressionEvents.count { if case .comeback = $0 { true } else { false } }
      totals.returners += read.progressionEvents.count { if case .returner = $0 { true } else { false } }
      totals.achievements += read.progressionEvents.count { if case .achievement = $0 { true } else { false } }
      totals.days += read.dailyStates.count
      totals.logs += read.questLogs.count
    }
    let exercised = [totals.events, totals.recoveries, totals.shields, totals.comebacks, totals.returners, totals.achievements, totals.days, totals.logs]
    #expect(exercised.allSatisfy { $0 > 0 }, "the histories exercise every part of the trail: \(totals)")
  }

  @Test func shouldReadNotesAndReflectionsOnlyWhenAskedForText() async throws {
    let device = try ReadsDevice()
    try await device.createStandardQuests()
    try await device.issue(.accountSetTimeZone(try TimeZoneChange(identifier: "Europe/London")), on: ReadsDevice.monday, minute: 2)
    let monday = ReadsDevice.monday
    let skip = try device.command(.questSkip(QuestBreak(occurrence: Occurrence(quest: ReadsDevice.routine, date: monday), reasonTag: .travel, hasNote: true)), on: monday)
    let note = try CommandNoteRecord(command: skip.id, text: "the train was cancelled again")
    _ = try await device.store.write { transaction in
      try skip.append(in: &transaction)
      try note.append(in: &transaction)
    }
    try await device.walk(to: ReadsDevice.day(1), minute: 600)
    let recovery = try device.command(.recoveryComplete(RecoveryCompletion(hasReflection: true)), on: ReadsDevice.day(1), minute: 620)
    let reflection = try CommandNoteRecord(command: recovery.id, text: "a short walk instead felt fine")
    _ = try await device.store.write { transaction in
      try recovery.append(in: &transaction)
      try reflection.append(in: &transaction)
    }
    try await device.walk(to: ReadsDevice.day(2), minute: 600)

    let withText = try await source(device).insightState(includingText: true)
    #expect(withText.normalized == (try await expected(device, through: ReadsDevice.day(2), minute: 600, includingText: true)))
    #expect(withText.profile.timeZone == "Europe/London")
    #expect(withText.questLogs.contains { $0.reasonNote == note.text && $0.reasonTag == ReasonTag.travel.rawValue })
    #expect(withText.progressionEvents.contains { $0.reflectionText == reflection.text })

    let withoutText = try await source(device).insightState(includingText: false)
    #expect(withoutText.normalized == (try await expected(device, through: ReadsDevice.day(2), minute: 600, includingText: false)))
    #expect(withoutText.questLogs.allSatisfy { $0.reasonNote == nil && $0.reflectionText == nil })
    #expect(withoutText.progressionEvents.allSatisfy { $0.reflectionText == nil })
  }

  @Test func shouldReadAnEmptyHistoryInTheDevicesZoneBeforeAnyIsSet() async throws {
    let device = try ReadsDevice()
    let state = try await source(device).insightState(includingText: true)
    #expect(state == InsightReplayState(profile: InsightProfile(timeZone: "Asia/Tokyo", intensityMode: .standard)))
  }

  @Test func shouldKeepTheWholeHeroTrailWhileScreensListTheLatestVisible() async throws {
    let device = try ReadsDevice()
    try await device.createStandardQuests()
    for day in 0..<20 {
      try await device.issue(.questComplete(Occurrence(quest: ReadsDevice.anchor, date: ReadsDevice.day(day))), on: ReadsDevice.day(day), minute: 430)
      try await device.issue(.questComplete(Occurrence(quest: ReadsDevice.routine, date: ReadsDevice.day(day))), on: ReadsDevice.day(day), minute: 500)
    }
    try await device.walk(to: ReadsDevice.day(20), minute: 600)
    let (all, recent) = try await device.store.read { transaction in
      (try MemoirDerived.heroEvents(in: transaction), try MemoirDerived.recentHeroEvents(in: transaction))
    }
    #expect(all.count > MemoirDerived.recentHeroEventLimit)
    #expect(recent.count == MemoirDerived.recentHeroEventLimit)
    #expect(recent.map(\.ordinal) == Array(all.filter { !HeroEventRow.hiddenTypes.contains($0.event.type) }.map(\.ordinal).suffix(32).reversed()))
    #expect(all.contains { HeroEventRow.hiddenTypes.contains($0.event.type) })
  }
}
