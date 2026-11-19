import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// Both devices run the same job while apart and then sync. What two attempts leave behind follows the plan's table (Jobs and attempts, Why a duplicate
/// attempt is safe): replica 0 writes first while they are apart and replica 1 last, so a first-writer-wins output is replica 0's and a register replica 1's.
@Suite("Chapter replicas: both run it while apart", TestTimeLimit.standard)
struct ChapterReplicaPartitionTests {
  private struct Ran {
    let job: EntityRef
    let first: AttemptID
    let second: AttemptID
  }

  private static func runApart(_ stage: ChapterStage, _ pair: ChapterReplicas, order: SyncOrder) async throws -> Ran {
    try await pair.prepare(for: stage)
    let first = try #require(try await stage.start(on: pair[0], calls: stage.calls()).handle)
    #expect(await first.result == .settled(.succeeded))
    let second = try #require(try await stage.start(on: pair[1], calls: stage.calls(variant: 1)).handle)
    #expect(await second.result == .settled(.succeeded))
    #expect(first.job == second.job, "the same request on two devices is one job")
    try await pair.sync(order)
    try await pair.expectConverged()
    for device in pair.devices {
      let attempts = try await device.snapshot(first.job).attempts
      #expect(attempts.map(\.id) == [first.attempt, second.attempt] && attempts.allSatisfy { $0.outcome == .succeeded })
      #expect(try await device.status(first.job) == .succeeded(first.attempt))
    }
    return Ran(job: first.job, first: first.attempt, second: second.attempt)
  }

  private static func outputs(_ pair: ChapterReplicas, job: EntityRef) async throws -> ChapterOutputs {
    let outputs = try await ChapterOutputs.read(pair[0], job: job)
    #expect(try await ChapterOutputs.read(pair[1], job: job) == outputs, "the replicas hold other outputs")
    return outputs
  }

  private static func seed(_ stage: ChapterStage, _ order: SyncOrder) -> UInt64 {
    0x34B0 + UInt64(stage.ordinal * 2 + (order == .firstToSecond ? 0 : 1))
  }

  /// A duplicate card is one card: its id comes from the job, and its first-writer-wins card is the first device's plan.
  @Test(arguments: SyncOrder.allCases)
  func shouldKeepOnePlanCardTheFirstDeviceStaged(order: SyncOrder) async throws {
    let pair = try await ChapterReplicas.make(seed: Self.seed(.plan, order))
    let ran = try await Self.runApart(.plan, pair, order: order)
    let outputs = try await Self.outputs(pair, job: ran.job)
    let card = try #require(outputs.cards[PlanCards.id(of: ran.job)])
    #expect(outputs.cards.count == 1 && card.run == ran.job.key.rawValue)
    #expect(String(describing: card.changeSet).contains("The Torn Page") && !String(describing: card.changeSet).contains("The Dark Stair"))
  }

  /// Each attempt appends its own revision and sets the head: the duplicate is one more version, the head is the register's last writer, and each attempt's
  /// judge pass stays bound to its own revision.
  @Test(arguments: SyncOrder.allCases)
  func shouldKeepBothRevisionsAndTheLastHeadWhenBothDevicesGenerate(order: SyncOrder) async throws {
    let pair = try await ChapterReplicas.make(seed: Self.seed(.generate, order))
    let ran = try await Self.runApart(.generate, pair, order: order)
    let outputs = try await Self.outputs(pair, job: ran.job)
    #expect(outputs.revisions.count == 2)
    let passes = outputs.reviews.filter(\.generationPass)
    #expect(passes.map(\.attempt) == [ran.first, ran.second] && Set(passes.compactMap(\.draftRevision)) == Set(outputs.revisions))
    let head = try #require(outputs.head)
    #expect(passes.last?.draftRevision == head)
    for device in pair.devices {
      let ref = try DraftRecord.ref(novel: ChapterReplicas.novel, chapter: ChapterStage.chapter)
      let body = try await device.store.read { transaction in try DraftRecord.readHead(ref, in: transaction).entry?.record.content.body }
      #expect(body == ChapterStage.otherBody)
      let lifecycle = try #require(try await ChapterTables.lifecycle(ChapterReplicas.novel, in: device.store)[ChapterStage.chapter])
      #expect(lifecycle.draft == head && lifecycle.review == .needsReview)
    }
  }

  /// Model reviews are appended items bound to a revision: both attempts' reviews stay, and the latest judge review of the current text is the one that counts
  /// on both replicas.
  @Test(arguments: SyncOrder.allCases)
  func shouldKeepBothReviewsAndCountTheSameLatestWhenBothDevicesReview(order: SyncOrder) async throws {
    let pair = try await ChapterReplicas.make(seed: Self.seed(.review, order))
    let ran = try await Self.runApart(.review, pair, order: order)
    let outputs = try await Self.outputs(pair, job: ran.job)
    #expect(outputs.reviews.map(\.attempt) == [ran.first, ran.second] && Set(outputs.reviews.map(\.draftRevision)) == [outputs.head])
    let latest = try await pair[0].store.chapterReviews(novel: ChapterReplicas.novel, chapter: ChapterStage.chapter).latest
    #expect(try await pair[1].store.chapterReviews(novel: ChapterReplicas.novel, chapter: ChapterStage.chapter).latest == latest)
    #expect(latest.first { $0.review.reviewKind == .known(.judge) }?.review.attempt == ran.second)
  }

  /// One finalize review per attempt; the first to become ready is the one the job keeps, and a chapter both devices finalized on approval holds one canon,
  /// the first commit's, bound to the review it read. Each commit asked for the refresh of its own canon, and the one whose canon lost stages nothing
  /// (chapter-canon-refresh.service.ts:108-111, natively by canon).
  @Test(arguments: SyncOrder.allCases)
  func shouldFinalizeOnceOnTheFirstReadWhenBothDevicesReadTheApprovedChapter(order: SyncOrder) async throws {
    let pair = try await ChapterReplicas.make(seed: Self.seed(.finalizeReview, order))
    let ran = try await Self.runApart(.finalizeReview, pair, order: order)
    let outputs = try await Self.outputs(pair, job: ran.job)
    #expect(outputs.reads.map(\.attempt) == [ran.first, ran.second])
    let canon = try #require(outputs.canon)
    #expect(canon.review?.id == outputs.reads.first?.id)
    #expect(String(describing: canon.review?.kept).contains("the lighthouse") && !String(describing: canon.review?.kept).contains("the lamp room"))
    for device in pair.devices { #expect(try await Projection.finals(in: device.store).count == 1) }

    let current = try await pair[0].engine.requestCanonRefresh(novel: ChapterReplicas.novel, chapter: ChapterStage.chapter)
    #expect(outputs.refreshJobs.count == 2 && outputs.refreshJobs.contains(current))
    let lost = try #require(outputs.refreshJobs.first { $0 != current })
    pair[1].model.queue(ChapterStage.canonRefresh.calls())
    #expect(try await pair[1].engine.run(job: lost.ref).result == .settled(.succeeded))
    try await pair.expectConverged()
    let refreshed = try await ChapterOutputs.read(pair[0], job: lost.ref)
    #expect(refreshed.reports.isEmpty && refreshed.cards[RefreshRecords.card(of: lost.ref)] == nil)
  }

  /// The report is first-writer-wins, and so is the card both attempts stage under the job's id: the first device's report and card, the report naming the card.
  @Test(arguments: SyncOrder.allCases)
  func shouldKeepTheFirstReportAndItsCardWhenBothDevicesRefresh(order: SyncOrder) async throws {
    let pair = try await ChapterReplicas.make(seed: Self.seed(.canonRefresh, order))
    let ran = try await Self.runApart(.canonRefresh, pair, order: order)
    let outputs = try await Self.outputs(pair, job: ran.job)
    let report = try #require(outputs.reports.first)
    let card = try #require(outputs.cards[RefreshRecords.card(of: ran.job)])
    #expect(outputs.reports.count == 1 && report.attempt == ran.first && report.proposal == RefreshRecords.card(of: ran.job))
    #expect(card.summary == report.copy && String(describing: card.changeSet).contains("The keeper of the lighthouse."))
  }

  /// Pins the residue G28 recorded: the report and the card race separately, so when the first device's refresh stages nothing and the second's stages a card,
  /// the first device's report, naming no card, wins and the second device's card still waits on the author.
  @Test func shouldKeepTheFirstReportAndTheOtherDevicesCardWhenOnlyTheSecondStagesOne() async throws {
    let pair = try await ChapterReplicas.make(seed: 0x34BA)
    try await pair.prepare(for: .canonRefresh)
    let first = try #require(try await ChapterStage.canonRefresh.start(on: pair[0], calls: [ChapterStage.withholdingRefresh]).handle)
    #expect(await first.result == .settled(.succeeded))
    let second = try #require(try await ChapterStage.canonRefresh.start(on: pair[1], calls: ChapterStage.canonRefresh.calls(variant: 1)).handle)
    #expect(await second.result == .settled(.succeeded))
    try await pair.expectConverged()
    let outputs = try await Self.outputs(pair, job: first.job)
    let report = try #require(outputs.reports.first)
    #expect(outputs.reports.count == 1 && report.attempt == first.attempt && report.proposal == nil)
    #expect(outputs.cards[RefreshRecords.card(of: first.job)].map { String(describing: $0.changeSet).contains("A keeper who found the torn logbook.") } == true)
  }

  /// Pins the residue G29 recorded: a device that asks for the plan again after its first run succeeded asks for the next run, while a device that never
  /// heard of that run runs the first one itself, so the chapter waits on two plan cards, one per run, until the author decides.
  @Test func shouldStageOnePlanCardPerRunWhenOneDeviceReplansWhileTheOtherRunsTheFirstRun() async throws {
    let pair = try await ChapterReplicas.make(seed: 0x34BB)
    try await pair.prepare(for: .plan)
    let first = try #require(try await ChapterStage.plan.start(on: pair[0], calls: ChapterStage.plan.calls()).handle)
    #expect(await first.result == .settled(.succeeded))
    let again = try #require(try await ChapterStage.plan.start(on: pair[0], calls: ChapterStage.plan.calls()).handle)
    #expect(await again.result == .settled(.succeeded) && again.job != first.job)
    let other = try #require(try await ChapterStage.plan.start(on: pair[1], calls: ChapterStage.plan.calls(variant: 1)).handle)
    #expect(await other.result == .settled(.succeeded) && other.job == first.job)
    try await pair.expectConverged()
    let outputs = try await Self.outputs(pair, job: first.job)
    #expect(Set(outputs.cards.keys) == [PlanCards.id(of: first.job), PlanCards.id(of: again.job)])
    #expect(outputs.cards[PlanCards.id(of: first.job)].map { String(describing: $0.changeSet).contains("The Torn Page") } == true)
  }
}
