import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Memoir replay checkpoints", TestTimeLimit.quick)
struct ReplayCheckpointTests {
  private static let stamp = "stamp"
  private static let start = LocalDate(daysSinceEpoch: ReplaySamples.firstDay)!

  /// Quest creations on the day before `firstDay`, then random commands over ten days from one device, clocked in issue order.
  private static func history(seed: UInt64) throws -> [ReplayCommand] {
    var generator = SeededGenerator(seed: seed)
    let created = Int64(ReplaySamples.firstDay - 1) * ReplaySamples.millisPerDay + 6 * 3_600_000
    var commands = try zip(ReplaySamples.quests, try ReplaySamples.schedules()).map { quest, schedule in
      try ReplaySamples.command(.questCreate(QuestCreation(questId: quest, schedule: schedule)), at: created, offset: 0, using: &generator)
    }
    for day in 0..<10 {
      let date = try #require(start.adding(days: day))
      for minute in stride(from: 420, to: 1_380, by: 240) {
        let instant = Int64(date.daysSinceEpoch) * ReplaySamples.millisPerDay + Int64(minute) * 60_000
        commands.append(try ReplaySamples.command(try ReplaySamples.randomBody(on: date, using: &generator), at: instant, offset: 0, using: &generator))
      }
    }
    return try commands.enumerated().map { index, command in try ReplayFixture.entry(command, wall: Int64(index + 1)) }
  }

  /// The states a replay leaves just before each day closes.
  private static func boundaries(of commands: [ReplayCommand]) -> [ReplayState] {
    var boundaries = [ReplayState]()
    var state = ReplayState.initial
    for command in Replay.ordered(commands) { _ = Replay.step(command, to: &state) { (boundary: ReplayState) in boundaries.append(boundary) } }
    return boundaries
  }

  @Test func shouldRoundTripEveryBoundaryAndResumeAsAFullReplayDoes() throws {
    for seed in UInt64(1)...4 {
      let commands = try Self.history(seed: seed)
      let full = Replay.run(commands)
      let boundaries = Self.boundaries(of: commands)
      #expect(boundaries.count >= 9)
      for boundary in boundaries {
        let checkpoint = try ReplayCheckpoint(boundary, stamp: Self.stamp)
        let decoded = try checkpoint.state(expecting: Self.stamp)
        #expect(decoded == boundary)
        #expect(try decoded.canonicalJSON() == checkpoint.body, "decoding and encoding again gives the same bytes")
        let position = try #require(boundary.position)
        #expect(boundary == Replay.run(commands.filter { $0.position <= position }), "a boundary is a full replay of the commands up to it")
        let rest = commands.filter { $0.position > position }
        #expect(try Replay.extend(decoded, with: rest) == full, "a decoded checkpoint without recurrence cursors resumes to the same state")
      }
    }
  }

  /// Decoding gives the state back and encoding it again the same bytes; nil when the state is refused.
  private static func roundTrip(_ state: ReplayState) throws -> ReplayState? {
    let body = try state.canonicalJSON()
    guard let decoded = try? ReplayState(canonicalJSON: body) else { return nil }
    #expect(decoded == state)
    #expect(try decoded.canonicalJSON() == body)
    return decoded
  }

  private static func expectResumesFromEveryBoundary(_ boundaries: [ReplayState], of commands: [ReplayCommand], sourceLocation: SourceLocation = #_sourceLocation)
    throws
  {
    let full = Replay.run(commands)
    for boundary in boundaries {
      let decoded = try #require(try roundTrip(boundary), sourceLocation: sourceLocation)
      let position = try #require(boundary.position, sourceLocation: sourceLocation)
      #expect(try Replay.extend(decoded, with: commands.filter { $0.position > position }) == full, sourceLocation: sourceLocation)
    }
  }

  @Test(arguments: try ReplayScenario.all().map(\.id))
  func shouldRoundTripEveryReferenceScenarioAndResumeFromEveryStep(_ id: String) throws {
    let scenario = try #require(try ReplayScenario.all().first { $0.id == id })
    let run = try ReplayScenarioRun(scenario)
    let handmade = scenario.walk != true || scenario.steps.contains { $0.type.hasPrefix("seed.") }
    for state in run.boundaries + [run.state] where try Self.roundTrip(state) == nil {
      #expect(handmade, "only a state seeded by hand or left by the handlers without the walk, which replay never produces, may be refused")
    }
    let resumed = try ReplayScenarioRun(scenario, roundTripping: true)
    #expect(resumed.state == run.state, "resuming from the decoded state before every step ends where the scenario does")
    #expect(resumed.outcomes == run.outcomes)
    if !handmade { #expect(resumed.roundTrips == scenario.steps.count) }
  }

  @Test func shouldExerciseBoundariesInTheReferenceScenarios() throws {
    let runs = try ReplayScenario.all().filter { $0.walk == true }.map { try ReplayScenarioRun($0) }
    #expect(runs.map(\.boundaries.count).reduce(0, +) >= 5, "the walking scenarios close days after commands")
    #expect(runs.map(\.roundTrips).allSatisfy { $0 == 0 })
  }

  /// Settings staged and promoted, metrics, expenses, a subscription cycle, quick logs, a quest updated and deleted, a purchase, a lock, misses that arm
  /// Comeback and an absence the Returner answers, so every part of the state holds something.
  private static func broadHistory() throws -> [ReplayCommand] {
    let day0 = try MemoirStoreFixture.date("2026-01-05")
    let quests = (1...4).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-00000000f%03d", $0)) }
    let other = (1...8).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-00000000e%03d", $0)) }
    let recurrence = try RecurrenceRule(frequency: .daily, startDate: day0)
    let schedules = [
      try QuestSchedule(strictness: .anchor, startTimeMinutes: 420, durationMinutes: 30, statAffinity: .discipline, recurrence: recurrence),
      try QuestSchedule(strictness: .routine, startTimeMinutes: 480, durationMinutes: 60, statAffinity: .body, recurrence: recurrence),
      try QuestSchedule(strictness: .goal, statAffinity: .wealth, recurrence: recurrence),
      try QuestSchedule(strictness: .optional, statAffinity: .mind, optionalStreakOptIn: true, recurrence: recurrence),
    ]
    var bodies = [(day: Int, minute: Int, body: MemoirCommandBody)]()
    func on(_ day: Int, _ minute: Int, _ body: MemoirCommandBody) { bodies.append((day, minute, body)) }
    func date(_ day: Int) throws -> LocalDate { try #require(day0.adding(days: day)) }
    on(-1, 600, .accountSetTimeZone(try TimeZoneChange(identifier: "Europe/Berlin")))
    for (quest, schedule) in zip(quests, schedules) { on(-1, 610, .questCreate(QuestCreation(questId: quest, schedule: schedule))) }
    let metric = MetricReference(id: other[0], metricClass: .general)
    for day in [0, 1, 2, 3, 4, 5, 8, 9, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40] {
      for quest in quests.prefix(3) where !(day == 5 && quest == quests[0]) { on(day, 430, .questComplete(Occurrence(quest: quest, date: try date(day)))) }
    }
    on(1, 900, .metricCreate(metric))
    on(1, 905, .metricUpdate(metric))
    on(1, 910, .metricRegister(MetricRegistration(metric: metric, date: try date(1))))
    on(1, 915, .expenseCreate(ExpenseCreation(id: other[1])))
    on(1, 920, .expenseUpdate(RecordReference(id: other[1])))
    on(1, 925, .subscriptionCreate(RecordReference(id: other[2])))
    on(2, 900, .subscriptionConfirmCycle(CycleConfirmation(subscription: other[2], billingDate: try date(2))))
    on(2, 905, .journalSave(QuickLogEntry(id: other[3], date: try date(2))))
    on(2, 910, .mealSavePreset(RecordReference(id: other[4])))
    on(2, 915, .mealLogPreset(PresetMealEntry(id: other[5], presetId: other[4], date: try date(2))))
    on(2, 920, .weightSave(WeightEntry(date: try date(2))))
    on(2, 925, .sideQuestLog(SideQuestEntry(id: other[6], date: try date(2), statAffinity: .mind)))
    on(2, 930, .receiptScan(ReceiptScan(receiptId: other[7])))
    on(3, 900, .questUpdate(QuestUpdate(questId: quests[1], patch: try QuestSchedulePatch(durationMinutes: 45))))
    on(3, 905, .questDelete(QuestReference(questId: quests[3])))
    on(4, 900, .cosmeticPurchase(.badgeBronze))
    on(4, 905, .cosmeticEquip(.badgeBronze))
    on(4, 910, .titleDisplay(TitleDisplay(title: .steadyBuilder)))
    on(4, 915, .accountSetIntensityMode(IntensityModeChange(mode: .highIntensity)))
    on(4, 920, .accountSetTimeZone(try TimeZoneChange(identifier: "America/New_York")))
    on(4, 925, .accountSetReturnerThreshold(try ReturnerThresholdChange(days: 3)))
    on(8, 400, .planSetLock(try PlanLock(locking: [quests[0], quests[1]])))
    on(8, 1_200, .recoveryComplete(RecoveryCompletion()))
    on(6, 300, .questReschedule(try QuestReschedule(occurrence: Occurrence(quest: quests[0], date: try date(6)), toMinute: 600, reasonTag: .scheduleConflict)))
    on(6, 900, .questSkip(QuestBreak(occurrence: Occurrence(quest: quests[1], date: try date(6)), reasonTag: .travel)))
    on(31, 900, .metricDelete(MetricDeletion(metric: metric)))
    on(41, 600, .expenseDelete(RecordReference(id: other[1])))
    return try bodies.enumerated().map { index, entry in
      let instant = Int64(try date(entry.day).daysSinceEpoch) * ReplaySamples.millisPerDay + Int64(entry.minute) * 60_000
      let command = try MemoirCommand(
        id: MemoirStoreFixture.commandID(9_000 + index), body: entry.body, instantMillis: instant, utcOffsetMinutes: 0,
        issuedOn: try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: 0), rulesetVersion: 1)
      return try ReplayFixture.entry(command, wall: Int64(index + 1))
    }
  }

  @Test func shouldRoundTripABroadHistoryAndResumeFromEachOfItsBoundaries() throws {
    let commands = try Self.broadHistory()
    let state = Replay.run(commands)
    #expect(state.halt == nil)
    #expect(state.settings.timeZones.count == 2 && state.settings.intensityModes.count == 1 && state.settings.returnerThresholds.count == 1)
    #expect(state.records.metrics.values.contains { !$0.isActive } && !state.records.expenses.isEmpty && !state.records.confirmedCycles.isEmpty)
    #expect(!state.records.quickLogs.isEmpty && !state.records.mealPresets.isEmpty && !state.records.weightDates.isEmpty)
    #expect(!state.compassion.returnerEvents.isEmpty && !state.compassion.recoveries.isEmpty)
    #expect(!state.progression.cosmetics.isEmpty && !state.progression.achievements.isEmpty)
    #expect(state.quests.values.contains { !$0.isActive })
    #expect(state.days.values.contains { $0.comebackEvents.values.contains { $0.trigger != nil } })
    #expect(state.days.values.contains { ($0.crown?.banked?.xp ?? 0) > 0 })
    #expect(!state.reasonedReschedules.isEmpty && state.logs.all.contains { $0.value.reasonTag == .travel })
    #expect(try Self.roundTrip(state) != nil)
    try Self.expectResumesFromEveryBoundary(Self.boundaries(of: commands), of: commands)
  }

  @Test func shouldEncodeEqualStatesIdenticallyWhateverOrderBuiltThem() throws {
    var generator = SeededGenerator(seed: 7)
    let commands = try Self.history(seed: 3)
    let state = Replay.run(commands)
    let shuffled = Replay.run(generator.shuffled(commands + commands.prefix(5)))
    #expect(shuffled == state)
    #expect(try shuffled.canonicalJSON() == state.canonicalJSON())
    var stepped = ReplayState.initial
    for command in Replay.ordered(commands) { Replay.step(command, to: &stepped) }
    #expect(try stepped.canonicalJSON() == state.canonicalJSON())
  }

  @Test func shouldRefuseATamperedOrForeignCheckpoint() throws {
    let commands = try Self.history(seed: 2)
    let boundary = try #require(Self.boundaries(of: commands).last)
    let checkpoint = try ReplayCheckpoint(boundary, stamp: Self.stamp)

    var flipped = checkpoint.body
    let index = try #require(flipped.firstIndex(of: UInt8(ascii: "7")))
    flipped[index] = UInt8(ascii: "8")
    #expect(throws: ReplayCheckpointError.digestMismatch) { try Self.resealed(checkpoint, body: flipped, digest: checkpoint.digest).state(expecting: Self.stamp) }
    #expect(throws: ReplayCheckpointError.digestMismatch) {
      try ReplayCheckpoint(
        day: checkpoint.day, position: checkpoint.position, rulesetVersion: checkpoint.rulesetVersion, stamp: checkpoint.stamp, body: checkpoint.body,
        digest: String(repeating: "0", count: 64)
      ).state(expecting: Self.stamp)
    }
    #expect(throws: ReplayCheckpointError.stale) { try checkpoint.state(expecting: "another build") }
    #expect(throws: ReplayCheckpointError.stale) { try Self.resealed(checkpoint, rulesetVersion: 99).state(expecting: Self.stamp) }

    let earlier = try #require(Self.boundaries(of: commands).first)
    let moved = try Self.resealed(checkpoint, position: try #require(earlier.position))
    #expect(throws: ReplayCheckpointError.inconsistent) { try moved.state(expecting: Self.stamp) }

    var json = try #require(try CanonicalJSON.decode(checkpoint.body).objectValue)
    var hero = try #require(json["hero"]?.objectValue)
    hero["coins"] = .int((hero["coins"]?.intValue ?? 0) + 1)
    json["hero"] = .object(hero)
    let richer = try Self.resealed(checkpoint, body: CanonicalJSON.encode(.object(json)))
    #expect(throws: ReplayCheckpointError.self, "a resealed body whose totals are not the trail's sums is refused") { try richer.state(expecting: Self.stamp) }

    json = try #require(try CanonicalJSON.decode(checkpoint.body).objectValue)
    json["version"] = .int(Int64(ReplayState.codingVersion + 1))
    let newer = try Self.resealed(checkpoint, body: CanonicalJSON.encode(.object(json)))
    #expect(throws: ReplayCheckpointError.self, "a body of another coding version is refused") { try newer.state(expecting: Self.stamp) }
  }

  @Test func shouldCheckpointOnlyAStateThatTookCommandsInAndDidNotHalt() throws {
    #expect(throws: ReplayCheckpointError.notAtBoundary) { try ReplayCheckpoint(.initial, stamp: Self.stamp) }
    let future = try ReplayFixture.command(1, .recoveryComplete(RecoveryCompletion()), at: "2026-03-01T08:00:00Z", rulesetVersion: 2)
    let halted = Replay.run(try ReplayFixture.entries([future]))
    #expect(halted.halt != nil)
    #expect(throws: ReplayCheckpointError.notAtBoundary) { try ReplayCheckpoint(halted, stamp: Self.stamp) }
  }

  private static func resealed(
    _ checkpoint: ReplayCheckpoint, body: Data? = nil, digest: String? = nil, rulesetVersion: Int? = nil, position: ReplayPosition? = nil
  ) throws -> ReplayCheckpoint {
    let body = body ?? checkpoint.body
    let rulesetVersion = rulesetVersion ?? checkpoint.rulesetVersion
    let position = position ?? checkpoint.position
    return ReplayCheckpoint(
      day: checkpoint.day, position: position, rulesetVersion: rulesetVersion, stamp: checkpoint.stamp, body: body,
      digest: digest ?? ReplayCheckpoint.digest(checkpoint.day, position, rulesetVersion, checkpoint.stamp, body))
  }
}
