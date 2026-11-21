import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Memoir replay convergence", TestTimeLimit.property)
struct ReplayConvergenceTests {
  private static let replicaCount = 3
  private static let quests = (1...3).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-00000000c%03d", $0)) }
  private static let firstDay = 20_517
  private static let idEpoch = Date(timeIntervalSince1970: 1_700_000_000)

  private static func schedules() throws -> [QuestSchedule] {
    let recurrence = try RecurrenceRule(frequency: .daily, startDate: try MemoirStoreFixture.date("2026-03-01"))
    return [
      try QuestSchedule(strictness: .anchor, startTimeMinutes: 420, durationMinutes: 30, statAffinity: .discipline, recurrence: recurrence),
      try QuestSchedule(strictness: .routine, startTimeMinutes: 480, durationMinutes: 60, statAffinity: .body, recurrence: recurrence),
      try QuestSchedule(strictness: .goal, statAffinity: .wealth, recurrence: recurrence),
    ]
  }

  /// A command some device could issue: a quest action, a log edit, a quick log, a purchase or a setting, at an instant in the first week of March.
  private static func randomBody(using generator: inout SeededGenerator) throws -> (MemoirCommandBody, Int64) {
    let day = try #require(LocalDate(daysSinceEpoch: firstDay + generator.int(in: 0...5)))
    let instant = Int64(day.daysSinceEpoch) * 86_400_000 + Int64(generator.int(in: 360...1_380)) * 60_000
    let occurrence = Occurrence(quest: generator.pick(from: quests), date: try #require(day.adding(days: -generator.int(in: 0...2))))
    let tag = generator.chance(0.5) ? generator.pick(from: ReasonTag.allCases) : nil
    let body: MemoirCommandBody
    switch generator.int(in: 0...15) {
    case 0, 1, 2: body = .questComplete(occurrence)
    case 3: body = .questPartial(occurrence)
    case 4: body = .questSkip(QuestBreak(occurrence: occurrence, reasonTag: tag))
    case 5: body = .questPostpone(QuestBreak(occurrence: occurrence, reasonTag: tag))
    case 6:
      body = .questReschedule(
        try QuestReschedule(occurrence: occurrence, toMinute: generator.int(in: 0...1_439), acceptBeyondCap: generator.chance(0.5), reasonTag: tag))
    case 7: body = .questAttachReason(try QuestReason(occurrence: occurrence, reasonTag: tag ?? .other, hasNote: false))
    case 8: body = .questDeleteLog(occurrence)
    case 9: body = .journalSave(QuickLogEntry(id: UUID.v7(at: idEpoch, using: &generator), date: day))
    case 10: body = .sideQuestLog(SideQuestEntry(id: UUID.v7(at: idEpoch, using: &generator), date: day, statAffinity: generator.pick(from: StatAffinity.allCases)))
    case 11: body = .cosmeticPurchase(generator.pick(from: [CosmeticID.badgeBronze, .themeSunrise, .themeMidnight]))
    case 12: body = .cosmeticEquip(generator.pick(from: [CosmeticID.badgeBronze, .themeSunrise, .themeMidnight]))
    case 13: body = .accountSetIntensityMode(IntensityModeChange(mode: generator.pick(from: IntensityMode.allCases)))
    case 14: body = generator.chance(0.8) ? .planSetLock(try PlanLock(locking: Array(generator.shuffled(quests).prefix(generator.int(in: 1...3))))) : .planSetLock(.unlocked)
    default: body = .recoveryComplete(RecoveryCompletion())
    }
    return (body, instant)
  }

  private static func command(_ body: MemoirCommandBody, at instant: Int64, using generator: inout SeededGenerator) throws -> MemoirCommand {
    let offset = generator.pick(from: [0, 60, 330, -300])
    return try MemoirCommand(
      id: UUID.v7(at: idEpoch, using: &generator), body: body, instantMillis: instant, utcOffsetMinutes: offset,
      issuedOn: try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: offset), rulesetVersion: Ruleset.v1.version)
  }

  /// What the day walk would have opened: every day of the week, Comeback armed on alternate days and a Recovery pending on each.
  private static func seeded() throws -> ReplayState {
    var state = ReplayState.initial
    for offset in 0...5 {
      let date = try #require(LocalDate(daysSinceEpoch: firstDay + offset))
      state.days[date] = ReplayDay(
        date: date, intensityMode: .standard, rulesetVersion: 1, comeback: ComebackDayState(armed: offset.isMultiple(of: 2), fires: 0, armedViaRecovery: false))
      state.compassion.recoveries[date] = RecoveryQuest(
        id: MemoirStoreFixture.commandID(0x20_0000 + offset), date: date, sourceQuest: quests[0], triggerLogs: [], isReturnerDay: false, state: .pending)
    }
    return state
  }

  private static func replay(_ store: VaultStore) async throws -> ReplayState {
    let commands = try await store.read { transaction in try Replay.commands(in: transaction) }
    return Replay.run(commands, from: try seeded())
  }

  @Test func shouldDeriveTheSameStateOnEveryReplicaForAnyDeliveryOrder() async throws {
    var locksApplied = 0
    var recoveriesCompleted = 0
    var comebackFires = 0
    try await forAll(iterations: 10) { generator in
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: Self.replicaCount, registry: MemoirSchema.mainRegistry, seed: generator.next()))
      let creations = try zip(Self.quests, try Self.schedules()).map { quest, schedule in
        try Self.command(.questCreate(QuestCreation(questId: quest, schedule: schedule)), at: Int64(Self.firstDay - 1) * 86_400_000, using: &generator)
      }
      _ = try await replicas.write(0) { transaction in for creation in creations { try creation.append(in: &transaction) } }
      try await replicas.settle()

      var issued = creations.count
      for _ in 0..<12 {
        let writer = generator.int(in: 0...(Self.replicaCount - 1))
        let batch = try (0..<generator.int(in: 1...4)).map { _ in
          let (body, instant) = try Self.randomBody(using: &generator)
          return try Self.command(body, at: instant, using: &generator)
        }
        issued += batch.count
        await replicas.advanceClock(of: writer, by: .milliseconds(Int(generator.int(in: 1...5_000))))
        _ = try await replicas.write(writer) { transaction in for command in batch { try command.append(in: &transaction) } }
        if generator.chance(0.4) { _ = try await replicas.step(using: &generator) }
      }
      while try await replicas.step(using: &generator) {}
      try await replicas.settle()

      let first = try await Self.replay(replicas.store(0))
      #expect(first.outcomes.count == issued)
      #expect(first.halt == nil)
      #expect(first.hero.totalXP > 0, "the generated commands reach the ledger, not only refusals")
      for index in 1..<Self.replicaCount { #expect(try await Self.replay(replicas.store(index)) == first) }

      let commands = try await replicas.store(0).read { transaction in try Replay.commands(in: transaction) }
      for case .readable(let entry) in commands where first.outcomes[entry.record.id] == .applied {
        if case .planSetLock = try MemoirCommandBody(entry.record) { locksApplied += 1 }
      }
      recoveriesCompleted += first.compassion.recoveries.values.count { $0.state == .completed }
      comebackFires += first.days.values.reduce(0) { $0 + $1.comeback.fires }
      let duplicated = commands + commands.filter { _ in generator.chance(0.3) }
      #expect(Replay.run(generator.shuffled(duplicated), from: try Self.seeded()) == first, "any order of the same commands, repeats included, gives the same state")
      var folded = try Self.seeded()
      for command in Replay.ordered(commands) { Replay.apply(command, to: &folded) }
      #expect(folded == first, "applying one command at a time in clock order is the same as running them all")
    }
    #expect(locksApplied > 0, "the lock path runs")
    #expect(recoveriesCompleted > 0, "the Recovery path runs")
    #expect(comebackFires > 0, "the Comeback path runs")
  }
}
