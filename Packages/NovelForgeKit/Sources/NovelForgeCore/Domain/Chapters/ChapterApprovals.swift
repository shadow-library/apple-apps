import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

/// Approving a draft (apps/novel-forge-server/src/modules/generation/generation.service.ts:457). The approval is an appended item naming the revision the author
/// read and the plan terms it was approved under; whether it is in force, across devices, is the lifecycle's derivation (`ChapterFingerprint` rule 6).
public enum ChapterApprovals {
  /// The plan revision of an approval of a chapter without a live plan: revision ids are content hashes, never empty, so it names no plan head.
  public static let planlessRevision = ""

  /// generation.service.ts:457 with its guards in order (DRF_002, DRF_007, DRF_017, DRF_013, PLN_004, then DRF_013 while the lifecycle reads it generating, :482); in the
  /// same transaction it answers the open blocking findings (:505) and requests the revision's finalize review (:504). The app calls `VaultStore.approveChapter`.
  /// `confirmed` is how many open blocking findings the author agreed to override; nil overrides whatever is open.
  @discardableResult
  static func approve(
    novel: UUID, chapter: Int, revision: String, as intent: ApprovalIntent = .standard, id: UUID = UUID(), confirmed: Int? = nil, requester: ReplicaID,
    in transaction: inout WriteTransaction
  ) throws(DomainError) -> ChapterApproval {
    try transaction.requireNovel(novel)
    let head = try transaction.liveDraft(novel: novel, chapter: chapter)
    guard try !transaction.isFinal(novel: novel, chapter: chapter) else { throw .draftFinal(chapter) }
    let entry = try transaction.lifecycle(novel: novel, chapter: chapter, head: head.revision)
    var kept: StaleCause?
    if case .asWritten = intent { kept = entry.stale }
    if let stale = entry.stale, kept == nil { throw .draftStale(chapter: chapter, reason: stale.reason) }
    if case .reveal? = kept { throw .draftRevealStale(chapter) }
    guard revision.utf8.elementsEqual(head.revision.utf8) else { throw .draftConflict(chapter: chapter, head: head.revision) }
    if case .asWritten(let seen) = intent, let kept, kept != seen { throw .draftConflict(chapter: chapter, head: head.revision) }
    if let verdict = try transaction.revealVerdict(novel: novel, chapter: chapter), verdict.status == .violated {
      throw .planRevealsHeld(chapter: chapter, violations: verdict.reason ?? "")
    }
    guard entry.review != .generating else { throw .draftConflict(chapter: chapter, head: head.revision) }
    let plan = try transaction.planHead(novel: novel, chapter: chapter)
    let review = FinalizeReviewJobInput(revision: head.revision, body: head.content.body, plan: plan?.revision)
    let overridden = try overrideOpenBlocking(novel: novel, chapter: chapter, head: head, confirmed: confirmed, in: &transaction)
    if entry.review == .approved, let held = entry.approval {
      _ = try FinalizeReviewJobs.request(review, novel: novel, chapter: chapter, requester: requester, in: &transaction)
      return ChapterApproval(id: held, overridden: overridden)
    }
    let approval = ApprovalRecord(
      id: id, novel: novel, chapter: chapter, approvalKind: .known(kept == nil ? .standard : .asWritten), draftRevision: head.revision,
      planRevision: plan?.revision ?? planlessRevision, planTermsDigest: ChapterFingerprint.planTerms(plan?.record.content.contract),
      upstreamDigest: kept == nil ? nil : entry.differences)
    try storeCall { () throws(StoreError) in
      _ = try approval.append(in: &transaction)
      _ = try DraftRecord.mark(head.record.ref, revision: head.revision, [.approved], in: &transaction)
    }
    _ = try FinalizeReviewJobs.request(review, novel: novel, chapter: chapter, requester: requester, in: &transaction)
    return ChapterApproval(id: id, overridden: overridden)
  }

  /// apps/novel-forge-server/src/modules/review/review-records.ts:163: approving answers every blocking finding still open on the chapter's latest judge review,
  /// when that review read the head as it stands. Approve overrides the review the lifecycle gates on: its latest readable judge row, by clock then id; a remedy
  /// this version cannot read is left as it is.
  private static func overrideOpenBlocking(
    novel: UUID, chapter: Int, head: DraftHead, confirmed: Int?, in transaction: inout WriteTransaction
  ) throws(DomainError) -> Int {
    let rows = try transaction.sql { database -> [ChapterReviewEntry] in
      guard try database.tableExists(ChapterReviewEntry.databaseTableName) else { return [] }
      return try ChapterReviewEntry.filter(Column("novel") == novel && Column("chapter") == chapter && Column("kind") == ChapterReviewKind.judge.rawValue)
        .fetchAll(database)
    }
    guard let row = rows.max(by: ChapterReviewEntry.precedes),
      case .readable(let reading) = try storeCall({ () throws(StoreError) in try ChapterReviewRecord.read(row.ref, in: transaction) })
    else { return 0 }
    let latest = reading.record
    var remedies = [ReviewRemedyRecord]()
    var unreadable = Set<String>()
    for finding in latest.findings {
      let reading = try storeCall { () throws(StoreError) in
        try ReviewRemedyRecord.read(novel: novel, review: latest.id, finding: finding.id, in: transaction)
      }
      switch reading {
      case .absent: continue
      case .unreadable: unreadable.insert(finding.id)
      case .readable(let entry): remedies.append(entry.record)
      }
    }
    let judged = LatestJudgeReview(
      reviewed: ReviewedText(draftRevision: latest.draftRevision, bodyHash: latest.bodyHash), findings: latest.findings, remedies: remedies)
    let overrides = ReviewFindings.approvalOverrides(latest: judged, draft: ReviewedText(draftRevision: head.revision, body: head.content.body))
      .filter { !unreadable.contains($0.findingId) }
    if let confirmed, overrides.count > confirmed { throw .approvalOverridesUnconfirmed(chapter: chapter, open: overrides.count) }
    for override in overrides {
      let remedy = ReviewRemedy(action: .known(override.action), fingerprint: override.fingerprint, reason: override.reason)
      _ = try storeCall { () throws(StoreError) in
        try ReviewRemedyRecord.set(novel: novel, review: latest.id, finding: override.findingId, remedy, in: &transaction)
      }
    }
    return overrides.count
  }
}

/// An approval in force and how many open blocking findings it recorded as overridden (chapter-checks.ts:274-278).
public struct ChapterApproval: Sendable, Equatable {
  public let id: UUID
  public let overridden: Int
}

/// What a finalize review reads, bound to the revision approved (apps/novel-forge-server/src/modules/finalize-review/finalize-review-stage.ts:30-38): its job's
/// fingerprint is the revision, the hash of its prose and the plan head's revision, which is a content hash as the reference's brief hash is (decision 8).
struct FinalizeReviewJobInput: Sendable, Equatable {
  let revision: String
  let sourceHash: String
  let plan: String?

  private enum Member: String {
    case revision
    case sourceHash
    case plan
  }

  init(revision: String, sourceHash: String, plan: String?) {
    self.revision = revision
    self.sourceHash = sourceHash
    self.plan = plan
  }

  init(revision: String, body: String, plan: String?) {
    self.init(revision: revision, sourceHash: hashReviewedBody(body), plan: plan)
  }

  init?(json: JSONValue) {
    guard let members = json.objectValue, let revision = members[Member.revision.rawValue]?.stringValue,
      let sourceHash = members[Member.sourceHash.rawValue]?.stringValue
    else { return nil }
    let plan = members[Member.plan.rawValue]
    guard plan?.isNull ?? true || plan?.stringValue != nil else { return nil }
    self.init(revision: revision, sourceHash: sourceHash, plan: plan?.stringValue)
  }

  var json: JSONValue {
    [Member.revision.rawValue: .string(revision), Member.sourceHash.rawValue: .string(sourceHash), Member.plan.rawValue: plan.map(JSONValue.string) ?? .null]
  }

  var fingerprint: String { ChapterFingerprint.digest(json) }

  func reads(_ revision: String, body: String) -> Bool {
    self.revision.utf8.elementsEqual(revision.utf8) && sourceHash == hashReviewedBody(body)
  }
}

/// The finalize_review jobs of a chapter (apps/novel-forge-server/src/modules/generation/generation.service.ts:515-523), requested as `JobEngine.request` does:
/// the same input is one job, and a cancelled or failed one is asked for again as its next run.
enum FinalizeReviewJobs {
  static func key(_ input: FinalizeReviewJobInput, novel: UUID, chapter: Int, run: Int) throws(DomainError) -> JobKey {
    do throws(JobKeyError) {
      return try JobKey(
        scope: NovelJobAddress.scope(of: novel), kind: NovelJobKind.finalizeReview.rawValue, target: NovelJobAddress.target(chapter: chapter),
        fingerprint: input.fingerprint, run: run)
    } catch {
      throw .store(.invalidChange(error.errorDescription ?? error.code))
    }
  }

  /// The run the input's review is read by: the highest one, unless it was cancelled or its read failed, which approving again prepares anew
  /// (finalize-review-stage.ts:55-60).
  static func current(_ input: FinalizeReviewJobInput, novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) -> JobSnapshot? {
    let highest = try highestRun(input, novel: novel, chapter: chapter, in: transaction)
    guard highest > 0 else { return nil }
    let snapshot = try load(try key(input, novel: novel, chapter: chapter, run: highest).ref, in: transaction)
    guard let snapshot, !ended(snapshot) else { return nil }
    return snapshot
  }

  /// Fails closed: a job record of the input this version cannot read refuses the approval rather than request a run beside it.
  @discardableResult
  static func request(
    _ input: FinalizeReviewJobInput, novel: UUID, chapter: Int, requester: ReplicaID, in transaction: inout WriteTransaction
  ) throws(DomainError) -> JobKey {
    if let current = try current(input, novel: novel, chapter: chapter, in: transaction) { return current.job.request.key }
    let run = try highestRun(input, novel: novel, chapter: chapter, in: transaction) + 1
    let key = try key(input, novel: novel, chapter: chapter, run: run)
    do throws(JobRecordError) {
      _ = try JobRecords.request(JobRequest(key: key, payload: input.json, replica: requester), in: &transaction)
    } catch {
      throw domainError(error)
    }
    return key
  }

  /// Every finalize_review job of the chapter whose input names `revision`, whatever its plan.
  static func jobs(novel: UUID, chapter: Int, revision: String, in transaction: borrowing WriteTransaction) throws(DomainError) -> [JobSnapshot] {
    let refs = try storeCall { () throws(StoreError) in try requests(novel: novel, chapter: chapter, revision: revision, in: transaction) }
    var snapshots = [JobSnapshot]()
    for ref in refs.read { if let snapshot = try load(ref, in: transaction) { snapshots.append(snapshot) } }
    return snapshots
  }

  /// The finalize_review jobs of the chapter whose input names `revision`, among `candidates` (every job of the vault when nil, as a write reads them): `read`
  /// those whose input names it, `unreadable` those whose input this version cannot read.
  static func requests<Transaction: StateReading & ~Copyable>(
    novel: UUID, chapter: Int, revision: String, among candidates: [EntityRef]? = nil, in transaction: borrowing Transaction
  ) throws(StoreError) -> (read: [EntityRef], unreadable: [EntityRef]) {
    let (scope, target) = (NovelJobAddress.scope(of: novel), NovelJobAddress.target(chapter: chapter))
    var states = [(ref: EntityRef, state: EntityState)]()
    if let candidates {
      for ref in candidates { if let state = try transaction.state(of: ref, scope: .vault) { states.append((ref, state)) } }
    } else {
      states = try transaction.states(ofKind: JobSchema.jobKind, scope: .vault)
    }
    var read = [EntityRef]()
    var unreadable = [EntityRef]()
    for (ref, state) in states {
      guard let job = JobRecords.reading(state, of: ref).record else { continue }
      let key = job.request.key
      guard key.kind == NovelJobKind.finalizeReview.rawValue, key.scope == scope, key.target == target else { continue }
      guard let input = FinalizeReviewJobInput(json: job.request.payload) else {
        unreadable.append(ref)
        continue
      }
      if input.revision.utf8.elementsEqual(revision.utf8) { read.append(ref) }
    }
    return (read, unreadable)
  }

  /// Failed or cancelled with nothing left running, so no read of it will come; known with no clock, since only a running attempt's lease reads one.
  static func ended(_ snapshot: JobSnapshot) -> Bool {
    let attempts = snapshot.attempts
    if attempts.contains(where: { $0.outcome == .succeeded }) { return false }
    if cancelled(snapshot) { return true }
    guard !attempts.contains(where: { $0.outcome == .running }) else { return false }
    return attempts.last { $0.outcome != .stoodDown }?.outcome == .failed
  }

  private static func cancelled(_ snapshot: JobSnapshot) -> Bool {
    guard !snapshot.attempts.contains(where: { $0.outcome == .succeeded }) else { return false }
    return snapshot.job.cancel == .requested || snapshot.attempts.contains { $0.outcome == .cancelled }
  }

  private static func highestRun(_ input: FinalizeReviewJobInput, novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) -> Int {
    var run = 0
    while true {
      let ref = try key(input, novel: novel, chapter: chapter, run: run + 1).ref
      guard try storeCall({ () throws(StoreError) in try transaction.state(of: ref) }) != nil else { return run }
      run += 1
    }
  }

  private static func load(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(DomainError) -> JobSnapshot? {
    do throws(JobRecordError) {
      return try JobSnapshot.load(ref, in: transaction)
    } catch {
      throw domainError(error)
    }
  }

  private static func domainError(_ error: JobRecordError) -> DomainError {
    switch error {
    case .jobUnreadable(let ref, _), .attemptUnreadable(let ref, _): .unreadable(ref)
    case .store(let error): .store(error)
    default: .store(.invalidChange(error.errorDescription ?? error.code))
    }
  }
}
