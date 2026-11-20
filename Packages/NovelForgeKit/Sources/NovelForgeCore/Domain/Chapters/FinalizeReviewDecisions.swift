import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/classes/app-error-code.ts:295-308
public enum FinalizeAnswerError: ShadowError, Equatable {
  case noReview
  case preparing
  case readingFailed
  case proseChanged
  case itemNotFound(String)
  case editRefused(reason: String)
  case reasonRequired
  case alreadyApplied
  case domain(DomainError)

  public var code: String {
    switch self {
    case .noReview: "FRV_001"
    case .preparing: FinalizeReviewError.preparing.code
    case .readingFailed: FinalizeReviewError.readingFailed.code
    case .proseChanged: FinalizeReviewError.proseChanged.code
    case .itemNotFound: "FRV_008"
    case .editRefused: "FRV_009"
    case .reasonRequired: "FRV_010"
    case .alreadyApplied: "FRV_011"
    case .domain(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .noReview: "This chapter has no finalize review — approve it first"
    case .preparing: FinalizeReviewError.preparing.errorDescription
    case .readingFailed: FinalizeReviewError.readingFailed.errorDescription
    case .proseChanged: FinalizeReviewError.proseChanged.errorDescription
    case .itemNotFound: "That update is not part of this finalize review"
    case .editRefused(let reason): "An edited update must keep its kind and the record it is about — \(reason)"
    case .reasonRequired: "Say why you are skipping this update"
    case .alreadyApplied: "These updates were already applied when the chapter was finalized"
    case .domain(let error): error.errorDescription
    }
  }
}

extension FinalizeReviewChain {
  /// The head's chain and its answers for a write, through the same chain and answers `FinalizeReadiness` gates on; read from the transaction itself, so a
  /// read appended earlier in it counts.
  static func reads(
    novel: UUID, chapter: Int, head: String, in transaction: borrowing WriteTransaction
  ) throws(DomainError) -> (chain: [AppendedEntry<FinalizeReviewRecord>], answers: [String: [String: StoredFinalizeAnswer]]) {
    try storeCall { () throws(StoreError) in
      let chain = chain(try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).entries, head: head)
      return (chain, try answers(to: chain, novel: novel, chapter: chapter, in: transaction))
    }
  }

  /// The head's review in force as its answers leave it; nil when the head has no ready read.
  static func inForce(novel: UUID, chapter: Int, head: String, in transaction: borrowing WriteTransaction) throws(DomainError) -> Resolved? {
    let (chain, answers) = try reads(novel: novel, chapter: chapter, head: head, in: transaction)
    return resolve(chain: chain, answers: answers)
  }
}

/// The author's answers to a finalize review (apps/novel-forge-server/src/modules/finalize-review/finalize-review.service.ts:346-394). Each answer is a decision
/// record keyed by the head revision and the item, naming the change it answered by digest; an automatic keep is never written as one (decision 4).
enum FinalizeReviewDecisions {
  // finalize-review.service.ts:346
  static func decide(
    novel: UUID, chapter: Int, item key: String, decision: FinalizeDecision, edit: OrderedJSONObject? = nil, reason: String? = nil,
    in transaction: inout WriteTransaction
  ) throws(FinalizeAnswerError) -> StoredFinalizeAnswer {
    let reason = reason.map { $0.jsTrim() }.flatMap { $0.isEmpty ? nil : $0 }
    if decision == .skipped, reason == nil { throw .reasonRequired }
    let (head, review) = try openReview(novel: novel, chapter: chapter, in: transaction)
    let key = key.precomposedStringWithCanonicalMapping
    guard let entry = review.items.first(where: { $0.stored.key == key }) else { throw .itemNotFound(key) }
    var edited: ProposedChange?
    if decision == .edited {
      guard let item = entry.item else { throw .editRefused(reason: FinalizeEditRefusal.notEditable(field: key).reason) }
      do throws(FinalizeReviewError) {
        edited = try editedChange(item.proposed, edit ?? OrderedJSONObject([]))
      } catch {
        guard case .editRefused(let refusal) = error else { preconditionFailure("an edit is refused only as FRV_009") }
        throw .editRefused(reason: refusal.reason)
      }
    }
    let answer = StoredFinalizeAnswer(decision: .known(decision), proposalDigest: entry.proposalDigest, edit: edited?.json.objectValue, reason: reason)
    try write(answer, novel: novel, chapter: chapter, revision: head, item: key, in: &transaction)
    return answer
  }

  /// finalize-review.service.ts:368: every routine item still open is kept, each as the author's own answer.
  static func keepRoutine(novel: UUID, chapter: Int, in transaction: inout WriteTransaction) throws(FinalizeAnswerError) -> Int {
    let (head, review) = try openReview(novel: novel, chapter: chapter, in: transaction)
    let open = review.items.filter { $0.item.map { $0.triage == .routine && $0.decision == nil } ?? false }
    for entry in open {
      let answer = StoredFinalizeAnswer(decision: .known(.kept), proposalDigest: entry.proposalDigest)
      try write(answer, novel: novel, chapter: chapter, revision: head, item: entry.stored.key, in: &transaction)
    }
    return open.count
  }

  /// finalize-review.service.ts:382, each category once in the order given; the reviews already read keep what they kept.
  static func setAutoKeep(novel: UUID, categories: [FinalizeCategory], in transaction: inout WriteTransaction) throws(DomainError) -> [FinalizeCategory] {
    try transaction.requireNovel(novel)
    var seen = Set<FinalizeCategory>()
    let autoKeep = categories.filter { seen.insert($0).inserted }
    var edit = NovelEdit()
    edit.autoKeep = .set(autoKeep.map(StoredEnum.known))
    try transaction.edit(NovelRecord.self, NovelForgeKey.novel(novel), edit.fields)
    return autoKeep
  }

  /// finalize-review.service.ts:564-578 over stored reads: the head's review in force, refused once the chapter is final, while its read is still to come or
  /// failed, and when only other revisions were read.
  static func openReview(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(FinalizeAnswerError) -> (head: String, review: FinalizeReviewChain.Resolved)
  {
    let head = try domain { () throws(DomainError) in
      try transaction.requireNovel(novel)
      return try transaction.isFinal(novel: novel, chapter: chapter) ? nil : try transaction.liveDraft(novel: novel, chapter: chapter)
    }
    guard let head else { throw .alreadyApplied }
    let review = try domain { () throws(DomainError) in try FinalizeReviewChain.inForce(novel: novel, chapter: chapter, head: head.revision, in: transaction) }
    if let review {
      guard review.read.record.sourceHash == hashReviewedBody(head.content.body) else { throw .proseChanged }
      return (head.revision, review)
    }
    let jobs = try domain { () throws(DomainError) in try FinalizeReviewJobs.jobs(novel: novel, chapter: chapter, revision: head.revision, in: transaction) }
    if jobs.contains(where: { !FinalizeReviewJobs.ended($0) }) { throw .preparing }
    if !jobs.isEmpty { throw .readingFailed }
    let reads = try domain { () throws(DomainError) in
      try storeCall { () throws(StoreError) in try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction) }
    }
    throw reads.entries.isEmpty ? .noReview : .proseChanged
  }

  private static func domain<T>(_ body: () throws(DomainError) -> T) throws(FinalizeAnswerError) -> T {
    do throws(DomainError) {
      return try body()
    } catch {
      throw .domain(error)
    }
  }

  private static func write(
    _ answer: StoredFinalizeAnswer, novel: UUID, chapter: Int, revision: String, item: String, in transaction: inout WriteTransaction
  ) throws(FinalizeAnswerError) {
    let record: FinalizeDecisionRecord
    do throws(NovelForgeKeyError) {
      record = try FinalizeDecisionRecord(novel: novel, chapter: chapter, draftRevision: revision, item: item, answer: answer)
    } catch {
      throw .itemNotFound(item)
    }
    try domain { () throws(DomainError) in try transaction.create(record) }
  }
}

extension VaultStore {
  /// Keeps, skips or edits one update of the chapter's finalize review; a skip needs a reason, and `edit` names only the fields it changes.
  @discardableResult
  public func decideFinalizeItem(
    novel: UUID, chapter: Int, item: String, decision: FinalizeDecision, edit: [String: JSONValue]? = nil, reason: String? = nil
  ) async throws(FinalizeAnswerError) -> StoredFinalizeAnswer {
    let patch = edit.flatMap { OrderedJSON(.object($0)).objectValue }
    return try await writeAnswers { transaction throws(FinalizeAnswerError) in
      try FinalizeReviewDecisions.decide(novel: novel, chapter: chapter, item: item, decision: decision, edit: patch, reason: reason, in: &transaction)
    }
  }

  /// Keeps every routine update still open; returns how many.
  @discardableResult
  public func keepRoutineFinalizeItems(novel: UUID, chapter: Int) async throws(FinalizeAnswerError) -> Int {
    try await writeAnswers { transaction throws(FinalizeAnswerError) in try FinalizeReviewDecisions.keepRoutine(novel: novel, chapter: chapter, in: &transaction) }
  }

  /// The routine categories later reviews keep without asking.
  @discardableResult
  public func setFinalizeAutoKeep(novel: UUID, categories: [FinalizeCategory]) async throws(DomainError) -> [FinalizeCategory] {
    try await writeDomain { transaction throws(DomainError) in try FinalizeReviewDecisions.setAutoKeep(novel: novel, categories: categories, in: &transaction) }
  }

  /// The job reading the head's finalize review under the current plan, for "Run here"; nil before the head is approved.
  public func finalizeReviewJob(novel: UUID, chapter: Int) async throws(DomainError) -> EntityRef? {
    try await writeDomain { transaction throws(DomainError) in
      guard case .live(let head) = try transaction.draft(novel: novel, chapter: chapter) else { return nil }
      let input = FinalizeReviewJobInput(revision: head.revision, body: head.content.body, plan: try transaction.planHead(novel: novel, chapter: chapter)?.revision)
      return try FinalizeReviewJobs.jobs(novel: novel, chapter: chapter, revision: head.revision, in: transaction)
        .filter { $0.job.request.key.fingerprint == input.fingerprint }.max { $0.job.request.key.run < $1.job.request.key.run }?.job.ref
    }
  }

  private func writeAnswers<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(FinalizeAnswerError) -> T) async throws(FinalizeAnswerError) -> T {
    do {
      return try await write { transaction in try body(&transaction) }
    } catch {
      if case .aborted(let cause) = error, let answer = cause as? FinalizeAnswerError { throw answer }
      throw .domain(.store(error))
    }
  }
}
