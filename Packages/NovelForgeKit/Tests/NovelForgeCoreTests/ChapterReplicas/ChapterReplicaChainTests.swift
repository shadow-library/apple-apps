import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Chapter replicas: the whole chain", TestTimeLimit.standard)
struct ChapterReplicaChainTests {
  /// Each job runs on the device after the one that ran the job before it, and the author's step after each job is taken on the other device.
  @Test(arguments: [0, 1])
  func shouldTakeAChapterFromPlanToCanonWithTheStepsAlternatingBetweenReplicas(first: Int) async throws {
    let pair = try await ChapterReplicas.make(seed: 0x340 + UInt64(first))
    var jobs: [ChapterStage: EntityRef] = [:]
    for (position, stage) in ChapterStage.allCases.enumerated() {
      let (runner, author) = (pair[(first + position) % 2], pair[(first + position + 1) % 2])
      let job = try await runner.run(stage, completing: false)
      jobs[stage] = job
      try await pair.sync()
      try await stage.complete(on: author, job: job)
      try await pair.expectConverged()
    }
    #expect(pair[0].model.requests + pair[1].model.requests == 6)
    for device in pair.devices {
      #expect(try await device.isFinal())
      for (stage, job) in jobs {
        let attempts = try await device.snapshot(job).attempts
        #expect(attempts.count == 1 && attempts.first?.outcome == .succeeded, "\(stage) ran \(attempts.count) attempts")
      }
      let novel = ChapterReplicas.novel
      let (proposals, reports) = try await device.store.read { transaction in
        (
          try transaction.query { database in try ProposalState.filter(Column("novel") == novel).fetchAll(database) },
          try RefreshReportRecord.listing(novel: novel, chapter: ChapterStage.chapter, in: transaction).records
        )
      }
      let refresh = try #require(jobs[.canonRefresh])
      #expect(Set(proposals.map(\.proposal)) == [PlanCards.id(of: try #require(jobs[.plan])), RefreshRecords.card(of: refresh)])
      #expect(reports.count == 1 && reports.first?.proposal == RefreshRecords.card(of: refresh))
    }
  }
}
