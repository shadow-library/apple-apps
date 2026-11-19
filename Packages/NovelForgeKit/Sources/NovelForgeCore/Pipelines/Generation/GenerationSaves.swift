import Foundation
import GRDB
import OSLog
import ShadowCore
import ShadowJobs
import ShadowStore

extension DraftRecord {
  /// A revision kept beside the head becomes the head, keeping its body, parent and generation.
  static func promote(_ ref: EntityRef, revision: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try transaction.reassert(ref, revision: revision, head: true)
  }
}

/// Orchestrator decision 6: revisions are kept beside the head, which moves at the end only if unmoved; persistDraft writes over it (graph.ts:128-218).
enum GenerationSaves {
  static let logger = Logger(category: "chapter.generation")

  /// The attempt's saves in order, found by its run tag and job; each is written once, in the transaction that checkpoints it.
  static func saved<Transaction: StateReading & ~Copyable>(
    novel: UUID, chapter: Int, run: String, job: EntityKey, in transaction: borrowing Transaction
  ) throws(GenerationJobError) -> [String] {
    let ref = try domain { () throws(DomainError) in try ChapterRefs.draft(novel: novel, chapter: chapter) }
    let history = try stored { () throws(StoreError) in try DraftRecord.history(ref, in: transaction) }.history
    let revisions = history?.revisions.filter { entry in entry.body.body.map { $0.run == run && $0.job == job } ?? false } ?? []
    return revisions.reversed().map(\.id)
  }

  /// Save number `ordinal`: the first draft of an empty chapter is its head, any other is kept beside it; a final chapter refuses (graph.ts:190, 194).
  static func save(
    _ content: DraftContent, ordinal: Int, target: NovelJobTarget, run: String, job: EntityKey, startedOn head: String?, plan: String?, snapshots: [PendingSnapshot],
    at now: Date, in transaction: inout WriteTransaction
  ) throws(GenerationJobError) -> String {
    let (novel, chapter) = (target.novel, target.chapter)
    let earlier = try saved(novel: novel, chapter: chapter, run: run, job: job, in: transaction)
    guard earlier.count == ordinal else { throw .saves(expected: ordinal, found: earlier.count) }
    let ref = try domain { () throws(DomainError) in try ChapterRefs.draft(novel: novel, chapter: chapter) }
    let presence = try domain { () throws(DomainError) in
      guard try !transaction.isFinal(novel: novel, chapter: chapter) else { throw .draftFinal(chapter) }
      return try transaction.draft(novel: novel, chapter: chapter)
    }
    let revision: String
    do throws(StoreError) {
      switch presence {
      case .absent:
        _ = try record(novel: novel, chapter: chapter, content).create(in: &transaction)
        guard let created = try DraftRecord.history(ref, in: transaction).history?.head else { throw .invalidChange("the new draft has no head") }
        revision = created
      case .removed where head == nil:
        _ = try record(novel: novel, chapter: chapter, content).restore(in: &transaction)
        revision = try DraftRecord.revise(ref, content, in: &transaction).revision
      case .removed, .live:
        let kept = Set(try DraftRecord.history(ref, in: transaction).history?.revisions.map(\.id) ?? [])
        let parent = (earlier.last ?? head).flatMap { kept.contains($0) ? RevisionParent.revision($0) : nil } ?? .head
        revision = try DraftRecord.keep(ref, content, parent: parent, in: &transaction).revision
      }
    } catch {
      throw .store(error)
    }
    let captures = snapshots.map { snapshot in
      WriterSnapshotCapture(
        novel: novel, chapter: chapter, revision: revision, attempt: snapshot.attempt, role: snapshot.role, messages: snapshot.messages, keptBack: snapshot.keptBack,
        planRevision: plan, bibleHash: snapshot.bibleHash, promptKey: snapshot.promptKey, promptVersion: snapshot.promptVersion, route: snapshot.route,
        isolated: snapshot.isolated, run: run)
    }
    record(captures, ordinal: ordinal, at: now, in: transaction.database)
    return revision
  }

  /// Fire and forget (writer-snapshot.service.ts:89-101): a capture that fails is rolled back to its savepoint and logged, and the save goes on.
  private static func record(_ captures: [WriterSnapshotCapture], ordinal: Int, at now: Date, in database: Database) {
    for capture in captures {
      let id = derivedID("com.shadow.library.novelforgekit.writer-snapshot", "\(capture.run ?? "")|\(ordinal)|\(capture.role.rawValue)|\(capture.attempt)")
      do {
        try database.inSavepoint {
          try WriterSnapshots.record(capture, id: id, at: now, in: database)
          return .commit
        }
      } catch {
        logger.error("A writer attempt could not be captured role=\(capture.role.rawValue, privacy: .public) attempt=\(capture.attempt, privacy: .public)")
      }
    }
  }

  /// accept, acceptAsIs, awaitReview and finish (chapter-generation.graph.ts:884-914); the pass is stored only for the head (review-records.ts:48-49).
  static func finish(
    _ state: GenerationJobState, target: NovelJobTarget, run: String, job: EntityKey, attempt: AttemptID, in transaction: inout WriteTransaction
  ) throws(GenerationJobError) -> Bool {
    let (novel, chapter) = (target.novel, target.chapter)
    let saves = try saved(novel: novel, chapter: chapter, run: run, job: job, in: transaction)
    guard let judged = saves.last, let pass = state.pass else { throw .checkpoint }
    let expected = state.pinned.head ?? saves.first
    let ref = try domain { () throws(DomainError) in try ChapterRefs.draft(novel: novel, chapter: chapter) }
    var isHead = false
    let (final, presence) = try domain { () throws(DomainError) in
      (try transaction.isFinal(novel: novel, chapter: chapter), try transaction.draft(novel: novel, chapter: chapter))
    }
    if !final, case .live(let head) = presence {
      if head.revision == judged {
        isHead = true
      } else if head.revision == expected {
        try promote(judged, over: head, ref: ref, novel: novel, chapter: chapter, in: &transaction)
        isHead = true
      }
    }
    if !isHead {
      logger.notice("The chapter moved during its generation, so the judged revision is kept as a version chapter=\(chapter, privacy: .public)")
    }
    guard isHead, try stored({ () throws(StoreError) in try ChapterReviewRecord.read(id: attempt.uuid, in: transaction) }) == .absent else { return isHead }
    let outcome = GenerationJudgePass.outcome(body: state.prose, pass: pass)
    let review: ChapterReviewRecord
    do throws(ReviewRecordError) {
      review = try ChapterReviewRecord(
        id: attempt.uuid, novel: novel, chapter: chapter, reviewKind: .known(.judge), draftRevision: judged, bodyHash: hashReviewedBody(state.prose),
        disposition: .known(outcome.disposition), verdict: outcome.verdict, findings: outcome.findings, isolated: state.isolated || state.pinned.unrestricted,
        note: outcome.note, checked: outcome.checked, generationPass: true, job: job, attempt: attempt, calls: pass.calls)
    } catch {
      throw .record(error)
    }
    do throws(StoreError) {
      _ = try review.append(in: &transaction)
    } catch {
      throw .store(error)
    }
    return isHead
  }

  /// The author's working copy over the head is kept as a version first, as persistDraft keeps the body it replaces (chapter-generation.graph.ts:139-154).
  private static func promote(
    _ judged: String, over head: DraftHead, ref: EntityRef, novel: UUID, chapter: Int, in transaction: inout WriteTransaction
  ) throws(GenerationJobError) {
    do throws(DomainError) {
      _ = try ChapterDrafts.keepWorkingCopy(novel: novel, chapter: chapter, over: head, in: &transaction)
    } catch {
      throw .domain(error)
    }
    do throws(StoreError) {
      _ = try DraftRecord.promote(ref, revision: judged, in: &transaction)
    } catch {
      throw .store(error)
    }
  }

  private static func record(novel: UUID, chapter: Int, _ content: DraftContent) throws(StoreError) -> DraftRecord {
    do throws(NovelForgeKeyError) {
      return try DraftRecord(novel: novel, chapter: chapter, content: content)
    } catch {
      throw .invalidChange(error.errorDescription ?? error.code)
    }
  }

  static func stored<T>(_ body: () throws(StoreError) -> T) throws(GenerationJobError) -> T {
    do {
      return try body()
    } catch {
      throw .store(error)
    }
  }

  static func domain<T>(_ body: () throws(DomainError) -> T) throws(GenerationJobError) -> T {
    do {
      return try body()
    } catch {
      throw .domain(error)
    }
  }
}
