import Foundation
import NovelForgeCore
import ShadowCore
import ShadowJobs
import ShadowStore

nonisolated struct PendingQuery: Sendable, Hashable {
  let novel: UUID
  let replica: ReplicaID
  let now: LeaseInstant
}

/// Everything Waiting on you reads for one novel, in one transaction (phase 8 decision 6): its waiting cards and their actions, its chapters, the finalize
/// review of each approved chapter, and the jobs of every chapter that has one still open or failed, with where each stands for this device.
nonisolated struct PendingSnapshot: Equatable, Sendable {
  let cards: Derived<ChatTrayCards>
  let rows: Derived<[ChapterRow]>
  let headings: [Int: ChapterHeading]
  /// The ready read of each approved chapter's Story Bible updates.
  let finalize: [Int: FinalizeReviewScreen.Review]
  let jobs: NovelChapterJobs
  let placements: JobPlacements

  var changesAt: Date? { [jobs.changesAt, placements.changesAt].compactMap { $0 }.min() }

  static func load(_ query: PendingQuery, in transaction: ReadTransaction) throws -> PendingSnapshot {
    let rows = try ChapterList.load(query.novel, in: transaction).rows
    var finalize = [Int: FinalizeReviewScreen.Review]()
    for row in rows.value ?? [] where row.stage == .approved {
      let screen = try FinalizeReviewScreen.load(FinalizeReviewScreenQuery(novel: query.novel, chapter: row.chapter), in: transaction)
      if case .ready(let review) = screen.state { finalize[row.chapter] = review }
    }
    let jobs = try NovelChapterJobs.load(NovelChapterJobsQuery(novel: query.novel, now: query.now), in: transaction)
    let placements = try JobPlacements.load(JobPlacementQuery(jobs: jobs.jobs.map(\.job), replica: query.replica, now: query.now), in: transaction)
    return PendingSnapshot(
      cards: try ChatTrayCards.load(novel: query.novel, in: transaction), rows: rows,
      headings: try ChapterHeadings.load(query.novel, in: transaction).headings.value ?? [:], finalize: finalize, jobs: jobs, placements: placements)
  }
}

nonisolated struct PendingJob: Equatable, Sendable {
  let chapter: Int
  let line: ChapterJobLine
}

nonisolated struct PendingItem: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// A waiting card, or an applied card whose actions did not run, as the chat's tray lists it.
    case chat(ChatTrayItem)
    case review(chapter: Int, contradiction: Bool)
    /// `open` is how many of the read's updates still need the author's call.
    case finalize(chapter: Int, open: Int)
    case job(PendingJob)
  }

  let kind: Kind
  /// The chapter's title, when it has one.
  var heading: String?

  var id: String {
    switch kind {
    case .chat(let item): item.id
    case .review(let chapter, _): "review:\(chapter)"
    case .finalize(let chapter, _): "finalize:\(chapter)"
    case .job(let job): "job:\(job.line.job.kind):\(job.line.job.key.rawValue)"
    }
  }

  var chapter: Int? {
    switch kind {
    case .chat: nil
    case .review(let chapter, _), .finalize(let chapter, _): chapter
    case .job(let job): job.chapter
    }
  }
}

nonisolated struct PendingList: Equatable, Sendable {
  let items: [PendingItem]
  /// Part of what could wait on the author is not up to date on this device, so the list may be short.
  let isPartial: Bool

  var count: Int { items.count }
  var chats: [PendingItem] { items.filter { $0.chapter == nil } }
  var chapters: [PendingItem] { items.filter { $0.chapter != nil } }

  static let empty = PendingList(items: [], isPartial: false)
}

/// What waits on the author, in a stable order: the cards by age (pending and conflicted together, then those whose actions did not run, as the chat's tray
/// lists them), then chapter by chapter in number order, each chapter's draft to review or Story Bible updates to finalize before its jobs, the jobs in the
/// order they were asked for. A job waits on the author when it is queued for anyone but this device's own runtime, stopped here with Resume, waiting for
/// consent, or failed; a run going anywhere, or a job this device starts on its own, waits on nobody. Job lines are the chapter strip's (`ChapterWorkspaceStatus`), so a
/// row and the chapter's strip always agree.
nonisolated enum PendingItems {
  static func list(_ snapshot: PendingSnapshot, replica: ReplicaID, standing: JobsStanding) -> PendingList {
    let cards = snapshot.cards.value.map { ChatTrayItem.items(ChatTraySnapshot(cards: .available($0), lasts: []), activities: [:]) } ?? []
    let rows = Dictionary((snapshot.rows.value ?? []).map { ($0.chapter, $0) }) { first, _ in first }
    let jobs = snapshot.jobs.chapters.value ?? [:]
    let chapters = Set(rows.keys).union(snapshot.finalize.keys).union(jobs.keys).sorted()
    var items = cards.map { PendingItem(kind: .chat($0)) }
    for chapter in chapters {
      let row = rows[chapter]
      let heading = snapshot.headings[chapter]?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      if let row, row.stage != .final, row.review == .needsReview || row.review == .contradiction {
        items.append(PendingItem(kind: .review(chapter: chapter, contradiction: row.review == .contradiction), heading: heading))
      } else if let review = snapshot.finalize[chapter], row?.stage == .approved {
        items.append(PendingItem(kind: .finalize(chapter: chapter, open: review.items.count { $0.decision == nil }), heading: heading))
      }
      guard let chapterJobs = jobs[chapter] else { continue }
      let status = ChapterWorkspaceStatus(row: row, jobs: .available(chapterJobs), placements: snapshot.placements, replica: replica, standing: standing)
      items += status.lines.filter(waitsOnAuthor).map { PendingItem(kind: .job(PendingJob(chapter: chapter, line: $0)), heading: heading) }
    }
    let isPartial = snapshot.cards.isUnavailable || snapshot.rows.isUnavailable || snapshot.jobs.chapters.isUnavailable || snapshot.placements.placements.isUnavailable
    return PendingList(items: items, isPartial: isPartial)
  }

  static func waitsOnAuthor(_ line: ChapterJobLine) -> Bool {
    switch line.state {
    case .queued(let wait): wait.starter != .here
    case .interrupted, .waitingForConsent, .failed: true
    case .runningHere, .resumingHere, .runningOnAnotherDevice, .runningInAnotherCopy, .startedOnThisDevice: false
    }
  }
}

extension String {
  nonisolated fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
