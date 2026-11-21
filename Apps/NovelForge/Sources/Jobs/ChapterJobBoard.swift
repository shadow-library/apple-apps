import Foundation
import NovelForgeCore
import ShadowCore
import ShadowJobs
import ShadowStore

nonisolated struct ChapterJobBoardQuery: Sendable, Hashable {
  let novel: UUID
  let chapter: Int
  let replica: ReplicaID
  let now: LeaseInstant
}

/// A chapter's jobs and where each stands for this device, read in one transaction; a screen reads it again at `changesAt`.
nonisolated struct ChapterJobBoard: ReadModel {
  let chapter: ChapterJobs
  let placements: JobPlacements

  var jobs: Derived<[ChapterJob]> { chapter.jobs }

  var changesAt: Date? { [chapter.changesAt, placements.changesAt].compactMap { $0 }.min() }

  static func load(_ query: ChapterJobBoardQuery, in transaction: ReadTransaction) throws(StoreError) -> ChapterJobBoard {
    let chapter = try ChapterJobs.load(ChapterJobsQuery(novel: query.novel, chapter: query.chapter, now: query.now), in: transaction)
    let jobs = (chapter.jobs.value ?? []).map(\.job)
    return ChapterJobBoard(chapter: chapter, placements: try JobPlacements.load(JobPlacementQuery(jobs: jobs, replica: query.replica, now: query.now), in: transaction))
  }
}
