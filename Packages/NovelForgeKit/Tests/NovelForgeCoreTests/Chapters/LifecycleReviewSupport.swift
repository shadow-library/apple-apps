import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

/// The writes the review and generation pipelines will make, as the lifecycle reads them: judge reviews of a draft's head, remedies of their findings, and
/// generate jobs for a chapter.
enum ReviewWrites {
  static func finding(_ id: String, _ severity: ReviewFindingSeverity = .blocking, _ category: ReviewFindingCategory = .continuity) -> ReviewFinding {
    ReviewFinding(id: id, severity: .known(severity), category: .known(category), text: "Finding \(id).", fingerprint: "fp-\(id)")
  }

  /// A judge review of the chapter's head as it stands, or of `revision` with `body` when given.
  @discardableResult
  static func judge(
    novel: UUID, chapter: Int, findings: [ReviewFinding], verdict: String = "contradiction", generationPass: Bool = false, revision: String? = nil,
    body: String? = nil, id: UUID = UUID(), in transaction: inout WriteTransaction
  ) throws -> UUID {
    let ref = try DraftRecord.ref(novel: novel, chapter: chapter)
    let head = try ChapterWrites.head(novel: novel, chapter: chapter, in: transaction)
    let text = try body ?? DraftRecord.read(ref, in: transaction).entry?.record.content.body ?? ""
    let review = try ChapterReviewRecord(
      id: id, novel: novel, chapter: chapter, reviewKind: .known(.judge), draftRevision: revision ?? head, bodyHash: hashReviewedBody(text),
      disposition: .known(ReviewFindings.disposition(of: findings)), verdict: verdict, findings: findings, generationPass: generationPass)
    _ = try review.append(in: &transaction)
    return id
  }

  static func remedy(novel: UUID, review: UUID, finding: String, _ action: ReviewRemedyAction?, in transaction: inout WriteTransaction) throws {
    guard let action else {
      _ = try ReviewRemedyRecord.clear(novel: novel, review: review, finding: finding, in: &transaction)
      return
    }
    _ = try ReviewRemedyRecord.set(novel: novel, review: review, finding: finding, ReviewRemedy(action: .known(action), fingerprint: "fp-\(finding)"), in: &transaction)
  }

  static func generateKey(novel: UUID, chapter: Int, run: Int = 1) throws -> JobKey {
    try JobWorld.key(novel: novel, chapter: chapter, kind: .generate, run: run)
  }

  @discardableResult
  static func requestGeneration(novel: UUID, chapter: Int, run: Int = 1, in transaction: inout WriteTransaction) throws -> EntityRef {
    let key = try generateKey(novel: novel, chapter: chapter, run: run)
    _ = try JobRecords.request(JobRequest(key: key, payload: .null, replica: JobWorld.replicas[0]), in: &transaction)
    return key.ref
  }

  static func cancel(_ job: EntityRef, in transaction: inout WriteTransaction) throws {
    _ = try JobRecords.cancel(job, in: &transaction)
  }

  static func succeed(_ job: EntityRef, attempt: AttemptID, in transaction: inout WriteTransaction) throws {
    let replica = JobWorld.replicas[0]
    _ = try AttemptRecords.start(attempt, AttemptStart(job: job, replica: replica, started: JobWorld.instant(0), byHand: false, pinned: .null), step: nil, in: &transaction)
    _ = try AttemptRecords.update(attempt, AttemptUpdate(settlement: .succeeded), by: replica, in: &transaction)
  }

  static func attempt(_ seed: UInt64) throws -> AttemptID {
    var generator = SeededGenerator(seed: seed)
    return try JobWorld.attemptID(at: 0, &generator)
  }
}
