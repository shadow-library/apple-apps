import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

/// The refusals of finalize no other domain error states (app-error-code.ts:81-84, 296-309): FIN_004, the review gate's FRV_002-006 (FRV_003 from the
/// finalize_review job state), and an isolated chapter that only its author finalizes (decision 12).
public enum FinalizeRefusal: Hashable, Sendable {
  case openBlockingFindings(chapter: Int, count: Int)
  /// No read of the approved head is stored and none has ended: the commit asks for one in a write of its own (decision 2).
  case reviewPreparing(chapter: Int)
  case reviewFailed
  case proseChanged
  case unanswered(count: Int)
  case strandedReveal(milestone: String, facts: [String])
  case isolatedByAuthorOnly(chapter: Int)

  public var code: String {
    switch self {
    case .openBlockingFindings: "FIN_004"
    case .reviewPreparing: FinalizeReviewError.preparing.code
    case .reviewFailed: FinalizeReviewError.readingFailed.code
    case .proseChanged: FinalizeReviewError.proseChanged.code
    case .unanswered(let count): FinalizeReviewError.unanswered(count: count).code
    case .strandedReveal(let milestone, let facts): FinalizeReviewError.strandedReveal(StrandedReveal(milestone: milestone, facts: facts)).code
    case .isolatedByAuthorOnly: "chapters.isolated_author_only"
    }
  }

  public var message: String {
    switch self {
    case .openBlockingFindings(let chapter, let count): FinalizeBlocker.openBlockingFindings(chapter: chapter, count: count).message
    case .reviewPreparing(let chapter):
      "The Story Bible updates of chapter \(chapter) have not been read from the approved revision yet — they are being prepared; finalize once they are ready"
    case .reviewFailed: FinalizeReviewError.readingFailed.errorDescription ?? code
    case .proseChanged: FinalizeReviewError.proseChanged.errorDescription ?? code
    case .unanswered(let count): FinalizeReviewError.unanswered(count: count).errorDescription ?? code
    case .strandedReveal(let milestone, let facts): FinalizeReviewError.strandedReveal(StrandedReveal(milestone: milestone, facts: facts)).errorDescription ?? code
    case .isolatedByAuthorOnly(let chapter): "Chapter \(chapter) is isolated, so only its author finalizes it"
    }
  }
}

struct FinalizeCommitTarget {
  let chapter: Int
  let head: DraftHead
  let approval: UUID
  let review: FinalizeReviewChain.Resolved
  let answers: [String: [String: StoredFinalizeAnswer]]
}

/// The finalize gate as the commit runs it, inside its transaction: the head must be the approval's revision first, then everything `FinalizeReadiness`
/// refuses, in finalizeRefusals' order (apps/novel-forge-server/src/modules/generation/finalize-refusals.ts:35-46), except that what readiness reads from
/// derived rows and lets pass when an entry of them is faulted is read again here from the records, failing closed: the finalize review chain and its
/// answers, the chapter's judge reviews, and the final chapters before it.
enum FinalizeCommitGate {
  private static let registry = NovelForgeSchema.registry

  /// The per-entry rows the lifecycle's approval in force and open blocking findings come from, and the ledger the canon freezes; a plan world fault is the
  /// plan world's guard's (`planWorld`), as only a chapter with a plan reads it.
  private static let entryTables: Set<String> = [
    ChapterApprovalEntry.databaseTableName, ChapterReviewEntry.databaseTableName, CharacterKnowledgeEntry.databaseTableName,
  ]

  /// Of the record index, the kinds the frozen ledger reads through it: manual reveals (CharacterKnowledgeDerivation's index input).
  private static let indexedKinds: Set<EntityKind> = [NovelForgeKind.characterKnowledge.entityKind]

  private enum Rank: Int, Comparable {
    case draft
    case approval
    case stale
    case findings
    case review
    case finalizable
    case summary
    case reveals
    case order

    static func < (left: Rank, right: Rank) -> Bool { left.rawValue < right.rawValue }
  }

  static func check(novel: UUID, chapter requested: Int?, by initiator: FinalizeInitiator, in transaction: borrowing WriteTransaction) throws(DomainError)
    -> FinalizeCommitTarget
  {
    try transaction.requireNovel(novel)
    let chapter = try target(novel: novel, chapter: requested, in: transaction)
    let head = try transaction.liveDraft(novel: novel, chapter: chapter)
    guard try !transaction.isFinal(novel: novel, chapter: chapter) else { throw .draftFinal(chapter) }
    let entry = try transaction.lifecycle(novel: novel, chapter: chapter, head: head.revision)
    guard entry.review == .approved, let approval = entry.approval else { throw .draftNotApproved(chapter) }
    if try faulted(novel: novel, in: transaction) { throw .lifecycleUnavailable(chapter) }

    let readiness: FinalizeReadiness
    do throws(StoreError) {
      readiness = try FinalizeReadiness.load(FinalizeReadinessQuery(novel: novel, chapter: chapter), in: ReadTransaction(database: transaction.database, registry: registry))
    } catch {
      throw .store(error)
    }
    guard case .available(let blockers) = readiness.blockers else { throw .lifecycleUnavailable(chapter) }
    var refusals = blockers.map { (rank(of: $0), refusal($0, chapter: chapter)) }.filter { $0.0 != .review && $0.0 != .order }
    if let judge = try unreadableJudgeReview(novel: novel, chapter: chapter, in: transaction) { refusals.append((.findings, .unreadable(judge))) }
    let (chain, answers) = try readableChain(novel: novel, chapter: chapter, head: head, in: transaction)
    let revision = ReviewedRevision(revision: head.revision, body: head.content.body)
    if let blocker = FinalizeReviewChain.blocker(chain: chain, answers: answers, head: revision) {
      let failed = blocker == .reviewPreparing ? try readFailed(novel: novel, chapter: chapter, revision: head.revision, in: transaction) : false
      refusals.append((.review, failed ? .finalizeRefused(.reviewFailed) : refusal(blocker, chapter: chapter)))
    }
    for earlier in 1..<max(chapter, 1) where try !transaction.isFinal(novel: novel, chapter: earlier) {
      refusals.append((.order, .finalizeOutOfOrder(chapter)))
      break
    }
    if let first = refusals.min(by: { $0.0 < $1.0 }) { throw first.1 }
    guard let review = FinalizeReviewChain.resolve(chain: chain, answers: answers) else { throw .finalizeRefused(.reviewPreparing(chapter: chapter)) }
    if initiator == .approval, head.content.isolated || review.read.record.isolated { throw .finalizeRefused(.isolatedByAuthorOnly(chapter: chapter)) }
    return FinalizeCommitTarget(chapter: chapter, head: head, approval: approval, review: review, answers: answers)
  }

  // generation.service.ts:604-612
  static func target(novel: UUID, chapter: Int?, in transaction: borrowing WriteTransaction) throws(DomainError) -> Int {
    if let chapter { return chapter }
    guard let lowest = try transaction.lifecycleEntries(novel: novel).filter({ $0.review == .approved }).map(\.chapter).min() else { throw .draftNotFound(nil) }
    return lowest
  }

  private static func rank(of blocker: FinalizeBlocker) -> Rank {
    switch blocker {
    case .draftNotFound, .draftUnreadable, .draftFinal: .draft
    case .notApproved: .approval
    case .stale: .stale
    case .openBlockingFindings: .findings
    case .reviewPreparing, .proseChanged, .unanswered, .strandedReveal: .review
    case .notFinalizable: .finalizable
    case .summaryMissing: .summary
    case .planReveals: .reveals
    case .outOfOrder: .order
    }
  }

  private static func refusal(_ blocker: FinalizeBlocker, chapter: Int) -> DomainError {
    switch blocker {
    case .draftNotFound: .draftNotFound(chapter)
    case .draftUnreadable(let ref): .unreadable(ref)
    case .draftFinal(let chapter): .draftFinal(chapter)
    case .notApproved(let chapter): .draftNotApproved(chapter)
    case .stale(let chapter, let cause): .draftStale(chapter: chapter, reason: cause.reason)
    case .notFinalizable(let chapter): .isolatedWithoutSummary(chapter)
    case .summaryMissing(let chapter): .summaryMissing(chapter)
    case .planReveals(let chapter, let violations): .planRevealsHeld(chapter: chapter, violations: violations)
    case .outOfOrder(let chapter): .finalizeOutOfOrder(chapter)
    case .openBlockingFindings(let chapter, let count): .finalizeRefused(.openBlockingFindings(chapter: chapter, count: count))
    case .reviewPreparing: .finalizeRefused(.reviewPreparing(chapter: chapter))
    case .proseChanged: .finalizeRefused(.proseChanged)
    case .unanswered(let count): .finalizeRefused(.unanswered(count: count))
    case .strandedReveal(let milestone, let facts): .finalizeRefused(.strandedReveal(milestone: milestone, facts: facts))
    }
  }

  /// The chain `FinalizeReadiness` gates on, read from the records: a finalize review of the chapter, or an answer to an item of its chain, that this version
  /// cannot read may be the one in force, so it refuses.
  private static func readableChain(
    novel: UUID, chapter: Int, head: DraftHead, in transaction: borrowing WriteTransaction
  ) throws(DomainError) -> (chain: [AppendedEntry<FinalizeReviewRecord>], answers: [String: [String: StoredFinalizeAnswer]]) {
    if let unreadable = try unreadableRecord(FinalizeReviewRecord.self, novel: novel, chapter: chapter, in: transaction, including: { _ in true }) {
      throw .unreadable(unreadable)
    }
    let (chain, answers) = try FinalizeReviewChain.reads(novel: novel, chapter: chapter, head: head.revision, in: transaction)
    for read in chain {
      for item in read.record.items {
        guard let ref = try? FinalizeDecisionRecord.ref(novel: novel, chapter: chapter, draftRevision: read.record.draftRevision, item: item.key) else { continue }
        if case .unreadable = try storeCall({ () throws(StoreError) in try FinalizeDecisionRecord.read(ref, in: transaction) }) { throw .unreadable(ref) }
      }
    }
    return (chain, answers)
  }

  /// G21: a judge review of the chapter this version cannot read may hold the blocking findings the lifecycle would count; one whose kind cannot be read may
  /// be a judge review. One whose novel cannot be read is not attributed, as the chapter's listings leave it out.
  private static func unreadableJudgeReview(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) -> EntityRef? {
    try unreadableRecord(ChapterReviewRecord.self, novel: novel, chapter: chapter, in: transaction) { reader in
      guard let kind: String = try? reader.required(.kind) else { return true }
      return kind == ChapterReviewKind.judge.rawValue
    }
  }

  private static func unreadableRecord<Record: ChapterAppendedRecord>(
    _: Record.Type, novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction, including belongs: (FieldReader<Record.Member>) -> Bool
  ) throws(DomainError) -> EntityRef? {
    let states = try storeCall { () throws(StoreError) in try transaction.states(ofKind: Record.kind.entityKind, scope: .vault) }
    for (ref, state) in states {
      guard case .unreadable = Record.reading(state, of: ref) else { continue }
      guard case .appended(let appended) = state, let reader = FieldReader<Record.Member>(object: .object(appended.item)) else { continue }
      guard let owner: UUID = try? reader.required(Record.novelMember), owner == novel else { continue }
      if let stored: Int = try? reader.required(Record.chapterMember), stored != chapter { continue }
      if belongs(reader) { return ref }
    }
    return nil
  }

  /// FRV_003 from the job state, as answering reads it (`FinalizeReviewDecisions.openReview`): the head's reads were asked for and every one of them ended
  /// without a review.
  private static func readFailed(novel: UUID, chapter: Int, revision: String, in transaction: borrowing WriteTransaction) throws(DomainError) -> Bool {
    let jobs = try FinalizeReviewJobs.jobs(novel: novel, chapter: chapter, revision: revision, in: transaction)
    return !jobs.isEmpty && jobs.allSatisfy(FinalizeReviewJobs.ended)
  }

  /// A fault on one of `entryTables` that is the whole derivation's, this novel's, or an entry's whose novel is this one or cannot be told, and a record index
  /// entry fault of one of `indexedKinds` of this novel or none told: readiness shows entry faults and lets them pass, the commit does not.
  private static func faulted(novel: UUID, in transaction: borrowing WriteTransaction) throws(DomainError) -> Bool {
    let rows = try transaction.sql { database -> [(derivation: String, key: String)] in
      guard try database.tableExists(ProjectionFaults.table) else { return [] }
      return try Row.fetchAll(database, sql: "SELECT derivation, key FROM \(ProjectionFaults.table)").map { ($0["derivation"], $0["key"]) }
    }
    let own = ProjectionFaults.key(novel)
    var owners = [EntityKind: [String: UUID?]]()
    for row in rows {
      let indexed = row.derivation == IndexedRecord.databaseTableName
      guard indexed || entryTables.contains(row.derivation) else { continue }
      if row.key == ProjectionFaults.wholeDerivation || row.key == own { return true }
      if UUID(uuidString: row.key) != nil { continue }
      let kind = ProjectionFaults.kind(ofKey: row.key)
      if indexed, kind.map(indexedKinds.contains) != true { continue }
      guard let kind else { return true }
      if owners[kind] == nil { owners[kind] = try self.owners(of: kind, in: transaction) }
      guard let owner = owners[kind]?[row.key], let owner, owner != novel else { return true }
    }
    return false
  }

  /// Every entity of `kind` by its fault key, with the novel it belongs to: its natural key's, an appended item's novel member, or a job's scope.
  private static func owners(of kind: EntityKind, in transaction: borrowing WriteTransaction) throws(DomainError) -> [String: UUID?] {
    var owners = [String: UUID?]()
    for (ref, state) in try storeCall({ () throws(StoreError) in try transaction.states(ofKind: kind, scope: .vault) }) {
      owners[ProjectionFaults.key(ref)] = owner(of: state, ref: ref)
    }
    return owners
  }

  private static func owner(of state: EntityState, ref: EntityRef) -> UUID? {
    if let novel = try? NovelForgeKey(reading: state, of: ref).novel { return novel }
    if case .appended(let appended) = state { return UUID(json: appended.item[FinalizeReviewMember.novel.rawValue] ?? .null) }
    return JobRecords.reading(state, of: ref).record.flatMap { NovelJobAddress.novel(ofScope: $0.request.key.scope) }
  }
}
