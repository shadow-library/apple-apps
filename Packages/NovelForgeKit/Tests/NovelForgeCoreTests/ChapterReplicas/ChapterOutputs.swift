import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// What one job left on a replica, each output named by the attempt that wrote it where its record says.
struct ChapterOutputs: Sendable, Equatable {
  let revisions: [String]
  let head: String?
  let reviews: [ChapterReviewRecord]
  let reads: [FinalizeReviewRecord]
  let reports: [RefreshReportRecord]
  /// Every card of the novel as it was staged.
  let cards: [UUID: ProposalCard]
  let canon: Canon?
  let refreshJobs: [JobKey]

  static func read(_ device: ChapterDevice, job: EntityRef) async throws -> ChapterOutputs {
    try await device.store.read { transaction in try load(job: job, in: transaction) }
  }

  private static func load(job: EntityRef, in transaction: ReadTransaction) throws -> ChapterOutputs {
    let (novel, chapter) = (ChapterReplicas.novel, ChapterStage.chapter)
    let history = try DraftRecord.history(try DraftRecord.ref(novel: novel, chapter: chapter), in: transaction).history
    let revisions: [String] = (history?.revisions ?? []).filter { $0.body.body?.job == job.key }.map(\.id).sorted()
    let reviews: [ChapterReviewRecord] = try ChapterReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).entries.map(\.record).filter { $0.job == job.key }
    let reads: [FinalizeReviewRecord] = try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).records.filter { $0.job == job.key }
    let reports: [RefreshReportRecord] = try RefreshReportRecord.listing(novel: novel, chapter: chapter, in: transaction).records
    var cards: [UUID: ProposalCard] = [:]
    let states: [ProposalState] = try transaction.query { database in try ProposalState.filter(Column("novel") == novel).fetchAll(database) }
    for state in states { cards[state.proposal] = try ProposalRecord.read(id: state.proposal, in: transaction).entry?.record.card }
    let finalRef = try FinalChapterRecord.ref(novel: novel, chapter: chapter)
    let canon: Canon? = FinalChapterRecord.reading(try transaction.state(of: finalRef, scope: .vault), of: finalRef).entry?.record.canon
    let jobs: [JobRecord] = try transaction.states(ofKind: JobSchema.jobKind).compactMap { JobRecords.reading($0.state, of: $0.ref).record }
    let refreshJobs = jobs.map(\.request.key).filter { $0.kind == NovelJobKind.canonRefresh.rawValue }.sorted { $0.ref.key.rawValue < $1.ref.key.rawValue }
    return ChapterOutputs(
      revisions: revisions, head: history?.head, reviews: reviews, reads: reads, reports: reports, cards: cards, canon: canon, refreshJobs: refreshJobs)
  }

  func written(of stage: ChapterStage, job: EntityRef) -> Int {
    switch stage {
    case .plan: cards[PlanCards.id(of: job)] == nil ? 0 : 1
    case .generate: revisions.count
    case .review: reviews.count
    case .finalizeReview: reads.count
    case .canonRefresh: reports.count + (cards[RefreshRecords.card(of: job)] == nil ? 0 : 1)
    }
  }
}
