import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Memoir replay convergence", TestTimeLimit.property)
struct ReplayConvergenceTests {
  private static let replicaCount = 3
  private static let offlineReplica = 2
  private static let quests = (1...3).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-00000000c%03d", $0)) }
  private static let firstDay = 20_517
  private static let idEpoch = Date(timeIntervalSince1970: 1_700_000_000)
  private static let millisPerDay: Int64 = 86_400_000

  private static func schedules() throws -> [QuestSchedule] {
    let recurrence = try RecurrenceRule(frequency: .daily, startDate: try MemoirStoreFixture.date("2026-03-01"))
    return [
      try QuestSchedule(strictness: .anchor, startTimeMinutes: 420, durationMinutes: 30, statAffinity: .discipline, recurrence: recurrence),
      try QuestSchedule(strictness: .routine, startTimeMinutes: 480, durationMinutes: 60, statAffinity: .body, recurrence: recurrence),
      try QuestSchedule(strictness: .goal, statAffinity: .wealth, recurrence: recurrence),
    ]
  }

  /// A command some device could issue on its own day: a quest action (today's or an offline one for the days before), a log edit, a quick log, a purchase,
  /// a setting, a lock or a Recovery completion.
  private static func randomBody(on day: LocalDate, using generator: inout SeededGenerator) throws -> MemoirCommandBody {
    let occurrence = Occurrence(quest: generator.pick(from: quests), date: try #require(day.adding(days: -generator.int(in: 0...2))))
    let tag = generator.chance(0.5) ? generator.pick(from: ReasonTag.allCases) : nil
    switch generator.int(in: 0...15) {
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

  private static func command(_ body: MemoirCommandBody, at instant: Int64, offset: Int, using generator: inout SeededGenerator) throws -> MemoirCommand {
    try MemoirCommand(
      id: UUID.v7(at: idEpoch, using: &generator), body: body, instantMillis: instant, utcOffsetMinutes: offset,
      issuedOn: try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: offset), rulesetVersion: Ruleset.v1.version)
  }

  private static func commands(_ store: VaultStore) async throws -> [ReplayCommand] {
    try await store.read { transaction in try Replay.commands(in: transaction) }
  }

  /// What a device keeps between syncs: the state of the commands it has taken in, extended one command at a time and replayed in full only when one sorts
  /// before the latest taken.
  private struct Incremental {
    var state = ReplayState.initial
    var taken = Set<ReplayPosition>()
    var replays = 0
    var reopenedDays = 0

    mutating func catchUp(with commands: [ReplayCommand]) {
      for command in Replay.ordered(commands) where !taken.contains(command.position) {
        taken.insert(command.position)
        guard Replay.step(command, to: &state) == .outOfOrder else { continue }
        let before = state
        state = Replay.run(commands.filter { taken.contains($0.position) })
        replays += 1
        reopenedDays += before.days.count { date, day in day.isClosed && state.days[date] != day }
      }
    }
  }

  @Test func shouldDeriveTheSameStateOnEveryReplicaForAnyDeliveryOrderIncludingLateEarlierDatedCommands() async throws {
    var replays = 0
    var reopenedDays = 0
    var misses = 0
    var recoveries = 0
    var comebackArmed = 0
    var banked = 0
    try await forAll(iterations: 10) { generator in
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: Self.replicaCount, registry: MemoirSchema.mainRegistry, seed: generator.next()))
      let created = Int64(Self.firstDay - 1) * Self.millisPerDay + 6 * 3_600_000
      let creations = try zip(Self.quests, try Self.schedules()).map { quest, schedule in
        try Self.command(.questCreate(QuestCreation(questId: quest, schedule: schedule)), at: created, offset: 0, using: &generator)
      }
      _ = try await replicas.write(0) { transaction in for creation in creations { try creation.append(in: &transaction) } }
      try await replicas.settle()

      var dayOf = Array(repeating: 0, count: Self.replicaCount)
      var devices = Array(repeating: Incremental(), count: Self.replicaCount)
      var issued = creations.count
      let offlineRounds = generator.int(in: 2...6)..<generator.int(in: 8...12)
      for round in 0..<14 {
        let writer = generator.int(in: 0...(Self.replicaCount - 1))
        if generator.chance(0.6) {
          dayOf[writer] = min(dayOf[writer] + 1, 9)
          await replicas.advanceClock(of: writer, by: .seconds(86_400))
        }
        await replicas.advanceClock(of: writer, by: .milliseconds(Int(generator.int(in: 1...5_000))))
        let day = try #require(LocalDate(daysSinceEpoch: Self.firstDay + dayOf[writer]))
        let offset = writer == 1 ? 60 : 0
        let batch = try (0..<generator.int(in: 1...4)).map { _ in
          let instant = Int64(day.daysSinceEpoch) * Self.millisPerDay + Int64(generator.int(in: 360...1_380)) * 60_000 - Int64(offset) * 60_000
          return try Self.command(try Self.randomBody(on: day, using: &generator), at: instant, offset: offset, using: &generator)
        }
        issued += batch.count
        _ = try await replicas.write(writer) { transaction in for command in batch { try command.append(in: &transaction) } }

        let offline = offlineRounds.contains(round)
        for from in 0..<Self.replicaCount {
          for to in 0..<Self.replicaCount where from != to && generator.chance(0.5) {
            if offline && (from == Self.offlineReplica || to == Self.offlineReplica) { continue }
            let available = await replicas.deliverable(from: from, to: to)
            if available > 0 { _ = try await replicas.deliver(from: from, to: to, atMost: generator.int(in: 1...available)) }
          }
        }
        for index in 0..<Self.replicaCount {
          if dayOf[index] < dayOf[writer] && !(offline && index == Self.offlineReplica) && generator.chance(0.5) { dayOf[index] = dayOf[writer] }
          let commands = try await Self.commands(replicas.store(index))
          devices[index].catchUp(with: commands)
          #expect(devices[index].state == Replay.run(commands), "a device extending its state agrees with a full replay of what it holds")
        }
      }
      try await replicas.settle()

      let first = try await Self.commands(replicas.store(0))
      let state = Replay.run(first)
      #expect(state.outcomes.count == issued)
      #expect(state.halt == nil)
      #expect(state.hero.totalXP > 0, "the generated commands reach the ledger, not only refusals")
      for index in 0..<Self.replicaCount {
        let commands = try await Self.commands(replicas.store(index))
        #expect(Replay.run(commands) == state)
        devices[index].catchUp(with: commands)
        #expect(devices[index].state == state, "every device's extended state converges on the full replay")
        replays += devices[index].replays
        reopenedDays += devices[index].reopenedDays
      }
      let duplicated = first + first.filter { _ in generator.chance(0.3) }
      #expect(Replay.run(generator.shuffled(duplicated)) == state, "any order of the same commands, repeats included, gives the same state")
      var folded = ReplayState.initial
      for command in Replay.ordered(first) { #expect(Replay.step(command, to: &folded) != .outOfOrder) }
      #expect(folded == state, "stepping one command at a time in clock order is the same as running them all")
      let horizon = try #require(LocalDate(daysSinceEpoch: Self.firstDay + 12))
      let stamp = IssueStamp(instantMillis: Int64(horizon.daysSinceEpoch) * Self.millisPerDay, utcOffsetMinutes: 0, issuedOn: horizon)
      #expect(Replay.run(first, through: stamp) == Replay.run(generator.shuffled(first), through: stamp))

      misses += state.logs.all.count { $0.value.state == .missed }
      recoveries += state.compassion.recoveries.count
      comebackArmed += state.days.values.count { $0.comebackEvents[.armed] != nil }
      banked += state.days.values.count { ($0.crown?.banked?.xp ?? 0) > 0 }
    }
    #expect(replays > 0, "a command delivered late sorts before ones a device had taken in")
    #expect(reopenedDays > 0, "a late command changes a day the device had closed")
    #expect(misses > 0 && recoveries > 0 && comebackArmed > 0 && banked > 0, "the walk closes days with misses, Recovery quests, Comeback and Crown")
  }
}
