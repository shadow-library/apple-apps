import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Memoir projection convergence", TestTimeLimit.property)
struct ProjectionConvergenceTests {
  private static let replicaCount = 3
  private static let offlineReplica = 2

  @Test func shouldKeepEveryReplicasDerivedTablesEqualToAFullReplayForAnyDeliveryOrder() async throws {
    var reopened = 0
    var resumed = 0
    var quickLogged = 0
    try await forAll(iterations: 8) { generator in
      let horizon = try ProjectionSupport.stamp(try #require(LocalDate(daysSinceEpoch: ReplaySamples.firstDay)), plus: 12)
      let reconcilers = try (0..<Self.replicaCount).map { _ in try MemoirReconciler(appVersion: "1", horizon: { horizon }) }
      let replicas = try await CausalReplicas(
        CausalReplicaSetup(count: Self.replicaCount, registry: MemoirSchema.mainRegistry, reconciler: { reconcilers[$0] }, seed: generator.next()))
      let created = Int64(ReplaySamples.firstDay - 1) * ReplaySamples.millisPerDay + 6 * 3_600_000
      let creations = try zip(ReplaySamples.quests, try ReplaySamples.schedules()).map { quest, schedule in
        try ReplaySamples.command(.questCreate(QuestCreation(questId: quest, schedule: schedule)), at: created, offset: 0, using: &generator)
      }
      _ = try await replicas.write(0) { transaction in for creation in creations { try creation.append(in: &transaction) } }
      try await replicas.settle()

      var dayOf = Array(repeating: 0, count: Self.replicaCount)
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
        _ = try await replicas.write(writer) { transaction in for command in batch { try command.append(in: &transaction) } }

        var closedBefore = [[LocalDate: DayRow]]()
        for index in 0..<Self.replicaCount {
          let days = try await ProjectionSupport.derived(in: replicas.store(index)).days
          closedBefore.append(Dictionary(uniqueKeysWithValues: days.filter(\.isClosed).map { ($0.date, $0) }))
        }
        let offline = offlineRounds.contains(round)
        for from in 0..<Self.replicaCount {
          for to in 0..<Self.replicaCount where from != to && generator.chance(0.5) {
            if offline && (from == Self.offlineReplica || to == Self.offlineReplica) { continue }
            let available = await replicas.deliverable(from: from, to: to)
            if available > 0 { _ = try await replicas.deliver(from: from, to: to, atMost: generator.int(in: 1...available), batch: generator.int(in: 1...available)) }
            let taken = await replicas.appliedCount(reader: to, writer: from)
            if taken > 0 && generator.chance(0.3) { try await replicas.redeliver(from: from, to: to, count: generator.int(in: 1...taken)) }
          }
        }
        for index in 0..<Self.replicaCount {
          let store = await replicas.store(index)
          let derived = try await ProjectionSupport.derived(in: store)
          #expect(derived == (try await ProjectionSupport.expected(in: store, through: horizon)), "replica \(index) after round \(round)")
          reopened += derived.days.count { day in closedBefore[index][day.date].map { $0 != day } ?? false }
          resumed += try await ProjectionSupport.checkpoints(in: store).isEmpty ? 0 : 1
        }
      }
      try await replicas.settle()

      let expected = try await ProjectionSupport.expected(in: replicas.store(0), through: horizon)
      #expect(expected.hero.first?.totalXP ?? 0 > 0)
      quickLogged += min(expected.quickLogs.count, expected.quickLogDays.count)
      for index in 0..<Self.replicaCount {
        let store = await replicas.store(index)
        #expect(try await ProjectionSupport.derived(in: store) == expected, "every replica converges on the same derived rows")
        try await ProjectionSupport.expectCheckpointsArePrefixReplays(in: store, stamp: reconcilers[index].fingerprint)
      }
    }
    #expect(reopened > 0, "a late command rewrote a day a replica had closed")
    #expect(resumed > 0, "replicas resumed from checkpoints")
    #expect(quickLogged > 0, "the quick-log outcomes and their days were compared")
  }
}
