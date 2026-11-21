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
      let created = Int64(ReplaySamples.firstDay - 1) * ReplaySamples.millisPerDay + 6 * 3_600_000
      let creations = try zip(ReplaySamples.quests, try ReplaySamples.schedules()).map { quest, schedule in
        try ReplaySamples.command(.questCreate(QuestCreation(questId: quest, schedule: schedule)), at: created, offset: 0, using: &generator)
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
        let day = try #require(LocalDate(daysSinceEpoch: ReplaySamples.firstDay + dayOf[writer]))
        let offset = writer == 1 ? 60 : 0
        let batch = try (0..<generator.int(in: 1...4)).map { _ in
          let instant = Int64(day.daysSinceEpoch) * ReplaySamples.millisPerDay + Int64(generator.int(in: 360...1_380)) * 60_000 - Int64(offset) * 60_000
          return try ReplaySamples.command(try ReplaySamples.randomBody(on: day, using: &generator), at: instant, offset: offset, using: &generator)
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
      let horizon = try #require(LocalDate(daysSinceEpoch: ReplaySamples.firstDay + 12))
      let stamp = IssueStamp(instantMillis: Int64(horizon.daysSinceEpoch) * ReplaySamples.millisPerDay, utcOffsetMinutes: 0, issuedOn: horizon)
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
