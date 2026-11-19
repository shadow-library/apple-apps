import Foundation
import GRDB
import ShadowCore
import ShadowStore

public struct FinalizeReadinessQuery: Sendable, Hashable {
  public let novel: UUID
  public let chapter: Int

  public init(novel: UUID, chapter: Int) {
    self.novel = novel
    self.chapter = chapter
  }
}

/// One reason finalize refuses the chapter, in finalizeRefusals' order (apps/novel-forge-server/src/modules/generation/finalize-refusals.ts:35-46).
public enum FinalizeBlocker: Hashable, Sendable {
  case draftNotFound
  case draftUnreadable(EntityRef)
  case draftFinal(chapter: Int)
  case notApproved(chapter: Int)
  case stale(chapter: Int, StaleCause)
  case openBlockingFindings(chapter: Int, count: Int)
  /// No read of the head's Story Bible updates is ready yet: a finalize review is mandatory (decision 2).
  case reviewPreparing
  case proseChanged
  case unanswered(count: Int)
  case strandedReveal(milestone: String, facts: [String])
  case notFinalizable(chapter: Int)
  case summaryMissing(chapter: Int)
  case planReveals(chapter: Int, violations: String)
  case outOfOrder(chapter: Int)

  public var code: String {
    guard case .openBlockingFindings = self else { return refusal.code }
    return "FIN_004"
  }

  public var message: String {
    // apps/novel-forge-server/src/classes/app-error-code.ts:81-84
    if case .openBlockingFindings(let chapter, _) = self {
      return "Chapter \(chapter) has a blocking review finding still open — change the text, dismiss the finding or approve over it before finalizing"
    }
    return refusal.errorDescription ?? refusal.code
  }

  private var refusal: any ShadowError {
    switch self {
    case .draftNotFound: DomainError.draftNotFound(nil)
    case .draftUnreadable(let ref): DomainError.unreadable(ref)
    case .draftFinal(let chapter): DomainError.draftFinal(chapter)
    case .notApproved(let chapter), .openBlockingFindings(let chapter, _): DomainError.draftNotApproved(chapter)
    case .stale(let chapter, let cause): DomainError.draftStale(chapter: chapter, reason: cause.reason)
    case .reviewPreparing: FinalizeReviewError.preparing
    case .proseChanged: FinalizeReviewError.proseChanged
    case .unanswered(let count): FinalizeReviewError.unanswered(count: count)
    case .strandedReveal(let milestone, let facts): FinalizeReviewError.strandedReveal(StrandedReveal(milestone: milestone, facts: facts))
    case .notFinalizable(let chapter): DomainError.isolatedWithoutSummary(chapter)
    case .summaryMissing(let chapter): DomainError.summaryMissing(chapter)
    case .planReveals(let chapter, let violations): DomainError.planRevealsHeld(chapter: chapter, violations: violations)
    case .outOfOrder(let chapter): DomainError.finalizeOutOfOrder(chapter)
    }
  }
}

/// What finalize would answer for the chapter now (generation.service.ts:635-640), from the lifecycle, the final set and the chapter's finalize reviews; a
/// fault that could change the answer makes it unavailable, which is not ready. The reference's authoring claim (JOB_002) has no counterpart: no device holds
/// a novel, and a chapter whose generate job is open is not approved. FIN_002 and FIN_003 need validation reports, which are not ported. A finalize review
/// record whose index row is faulted on its own is not seen, which can only show an older read of the same revision or none.
public struct FinalizeReadiness: ReadModel {
  public let blockers: Derived<[FinalizeBlocker]>
  public let faults: [ReadFault]

  public var isReady: Bool { blockers == .available([]) }

  private static let tables = [ChapterLifecycleEntry.databaseTableName, FinalChapterEntry.databaseTableName, IndexedRecord.databaseTableName]

  public static func load(_ query: FinalizeReadinessQuery, in transaction: ReadTransaction) throws(StoreError) -> FinalizeReadiness {
    let report = try ReadFaults(novel: query.novel, reading: tables, in: transaction)
    let blockers = try report.section(tables) { () throws(StoreError) in try blockers(of: query, in: transaction) }
    return FinalizeReadiness(blockers: blockers, faults: report.relevant)
  }

  private static func blockers(of query: FinalizeReadinessQuery, in transaction: ReadTransaction) throws(StoreError) -> [FinalizeBlocker] {
    let (novel, chapter) = (query.novel, query.chapter)
    let entry = try transaction.query { database in
      try ChapterLifecycleDerivation.request(for: novel).filter(Column("chapter") == chapter).fetchOne(database)
    }
    guard let entry else { return [.draftNotFound] }
    if entry.isFinal { return [.draftFinal(chapter: chapter)] }
    guard let head = entry.draft, let ref = try? DraftRecord.ref(novel: novel, chapter: chapter) else { return [.draftNotFound] }
    let content: DraftContent
    switch try DraftRecord.readHead(ref, in: transaction) {
    case .absent: return [.draftNotFound]
    case .unreadable: return [.draftUnreadable(ref)]
    case .readable(let draft):
      guard !draft.isRemoved else { return [.draftNotFound] }
      content = draft.record.content
    }
    var blockers = [FinalizeBlocker]()
    if entry.review != .approved { blockers.append(.notApproved(chapter: chapter)) }
    if let stale = entry.stale { blockers.append(.stale(chapter: chapter, stale)) }
    if entry.openBlocking > 0 { blockers.append(.openBlockingFindings(chapter: chapter, count: entry.openBlocking)) }
    if entry.review == .approved, let refusal = try reviewBlocker(novel: novel, chapter: chapter, head: ReviewedRevision(revision: head, body: content.body), in: transaction) {
      blockers.append(refusal)
    }
    let summaryBlank = content.summary?.jsTrim().isEmpty ?? true
    // common/finalize-gate.ts:21-24: an isolated chapter needs its summary and a non-empty continuation state.
    if content.isolated, summaryBlank || (content.state ?? [:]).isEmpty { blockers.append(.notFinalizable(chapter: chapter)) }
    if !content.isolated, summaryBlank { blockers.append(.summaryMissing(chapter: chapter)) }
    if case .reveal(let violations)? = entry.planStale { blockers.append(.planReveals(chapter: chapter, violations: violations)) }
    let finals = Set(try transaction.query { database in try FinalChapterEntry.filter(Column("novel") == novel && Column("chapter") < chapter).fetchAll(database) }.map(\.chapter))
    if !finals.isSuperset(of: 1..<max(chapter, 1)) { blockers.append(.outOfOrder(chapter: chapter)) }
    return blockers
  }

  private static func reviewBlocker(novel: UUID, chapter: Int, head: ReviewedRevision, in transaction: ReadTransaction) throws(StoreError) -> FinalizeBlocker? {
    let rows = try transaction.query { database in
      try IndexedRecord.filter(
        Column("novel") == novel && Column("kind") == NovelForgeKind.finalizeReview.rawValue && Column("chapter") == chapter
          && Column("status") == IndexedStatus.live.rawValue
      ).fetchAll(database)
    }
    var reads = [AppendedEntry<FinalizeReviewRecord>]()
    for row in rows {
      guard case .readable(let read) = try FinalizeReviewRecord.read(row.ref, in: transaction), read.record.novel == novel, read.record.chapter == chapter else { continue }
      reads.append(read)
    }
    let chain = FinalizeReviewChain.chain(reads, head: head.revision)
    let answers = try FinalizeReviewChain.answers(to: chain, novel: novel, chapter: chapter, in: transaction)
    return FinalizeReviewChain.blocker(chain: chain, answers: answers, head: head)
  }
}

/// The finalize review gate over stored reads (finalize-review-gate.ts:47-59): each revision's latest read, the head's last, answers carried along the chain.
enum FinalizeReviewChain {
  static func precedes(_ first: AppendedEntry<FinalizeReviewRecord>, _ second: AppendedEntry<FinalizeReviewRecord>) -> Bool {
    guard first.clock == second.clock else { return first.clock < second.clock }
    return first.record.ref < second.record.ref
  }

  /// One read per revision, its latest, oldest first and ending with the head's: a read stored after the head's last one never flows into it, as the reference
  /// carries answers only from the reviews before the one it stores (finalize-review.service.ts:518-561). Empty when the head has no read. A job keeps its first
  /// read of its revision (the pipeline appends no second), so a duplicate another device's attempt appended later never replaces the review the author answered.
  static func chain(_ reads: [AppendedEntry<FinalizeReviewRecord>], head: String) -> [AppendedEntry<FinalizeReviewRecord>] {
    var kept = Set<[String]>()
    var latest = [String: AppendedEntry<FinalizeReviewRecord>]()
    for read in reads.sorted(by: precedes) where kept.insert([read.record.job.rawValue, read.record.draftRevision]).inserted {
      latest[read.record.draftRevision] = read
    }
    guard let last = latest[head] else { return [] }
    return latest.values.filter { $0.record.draftRevision == head || precedes($0, last) }.sorted(by: precedes)
  }

  /// The answers given at each revision of the chain, by item key.
  static func answers<Transaction: StateReading & ~Copyable>(
    to chain: [AppendedEntry<FinalizeReviewRecord>], novel: UUID, chapter: Int, in transaction: borrowing Transaction
  ) throws(StoreError) -> [String: [String: StoredFinalizeAnswer]] {
    var answers = [String: [String: StoredFinalizeAnswer]]()
    for read in chain {
      let revision = read.record.draftRevision
      for item in read.record.items {
        guard let ref = try? FinalizeDecisionRecord.ref(novel: novel, chapter: chapter, draftRevision: revision, item: item.key),
          case .readable(let answer) = try FinalizeDecisionRecord.read(ref, in: transaction), !answer.isRemoved
        else { continue }
        answers[revision, default: [:]][item.key] = answer.record.answer
      }
    }
    return answers
  }

  /// The head's read with each item as the answers along the chain leave it; `item` is nil for one this version cannot read.
  struct Resolved: Sendable {
    struct Item: Sendable {
      let stored: StoredFinalizeItem
      let item: FinalizeReviewItem?

      /// The digest of the change it proposes, read from its stored shape when this version cannot parse it.
      var proposalDigest: String {
        item?.proposed.digest ?? sha256Hex(String(decoding: CanonicalJSON.encode(.object(stored.proposed)), as: UTF8.self))
      }
    }

    let read: AppendedEntry<FinalizeReviewRecord>
    let items: [Item]
    /// Items this version cannot read that no answer or automatic keep settles.
    let opaque: Int

    var resolved: [FinalizeReviewItem] { items.compactMap(\.item) }
  }

  /// Nil when the chain is empty; the chain ends with the head's read.
  static func resolve(chain: [AppendedEntry<FinalizeReviewRecord>], answers: [String: [String: StoredFinalizeAnswer]]) -> Resolved? {
    guard let last = chain.last else { return nil }
    var opaque = 0
    var headItems = [Resolved.Item]()
    let reviews = chain.map { read in
      let revision = read.record.draftRevision
      let answered = answers[revision] ?? [:]
      let parsed = read.record.items.map { Resolved.Item(stored: $0, item: item(of: $0)) }
      if read == last {
        opaque = parsed.filter { $0.item == nil && $0.stored.autoDecision?.known == nil && answered[$0.stored.key]?.decision.known == nil }.count
        headItems = parsed
      }
      return RevisionReview(revision: revision, items: parsed.compactMap(\.item), answers: answered.sorted { $0.key < $1.key }.compactMap(answer))
    }
    var resolved = resolveReviewChain(reviews).makeIterator()
    let items = headItems.map { Resolved.Item(stored: $0.stored, item: $0.item == nil ? nil : resolved.next()) }
    return Resolved(read: last, items: items, opaque: opaque)
  }

  /// An item of the head's read that this version cannot understand stays open unless it is answered or was kept on its own.
  static func blocker(chain: [AppendedEntry<FinalizeReviewRecord>], answers: [String: [String: StoredFinalizeAnswer]], head: ReviewedRevision) -> FinalizeBlocker? {
    guard let review = resolve(chain: chain, answers: answers), review.read.record.draftRevision == head.revision else { return .reviewPreparing }
    let opaque = review.opaque
    let snapshot = FinalizeReviewSnapshot(draftRevision: head.revision, sourceHash: review.read.record.sourceHash, status: .ready, items: review.resolved)
    switch reviewRefusal([snapshot], head) {
    case nil: return opaque > 0 ? .unanswered(count: opaque) : nil
    case .preparing?: return .reviewPreparing
    case .proseChanged?: return .proseChanged
    case .unanswered(let count)?: return .unanswered(count: count + opaque)
    case .strandedReveal(let stranded)?: return opaque > 0 ? .unanswered(count: opaque) : .strandedReveal(milestone: stranded.milestone, facts: stranded.facts)
    case .readingFailed?, .editRefused?: preconditionFailure("a stored finalize review is ready, and the gate edits nothing")
    }
  }

  static func item(of stored: StoredFinalizeItem) -> FinalizeReviewItem? {
    guard let category = stored.category.known, let triage = stored.triage.known, let basis = stored.basis.known,
      let proposed = ProposedChange(json: .object(stored.proposed))
    else { return nil }
    let decision = stored.autoDecision?.known
    return FinalizeReviewItem(
      itemKey: stored.key, category: category, triage: triage, basis: basis, subjectKey: stored.subject, claim: stored.claim, evidence: stored.evidence,
      proposed: proposed, flag: stored.flag?.known, dependents: stored.dependents, decision: decision, edited: nil, reason: nil, autoKept: decision != nil)
  }

  private static func answer(_ pair: (key: String, value: StoredFinalizeAnswer)) -> FinalizeAnswer? {
    guard let decision = pair.value.decision.known else { return nil }
    return FinalizeAnswer(
      itemKey: pair.key, decision: decision, proposalDigest: pair.value.proposalDigest, edited: pair.value.edit.flatMap { ProposedChange(json: .object($0)) },
      reason: pair.value.reason, autoKept: pair.value.auto)
  }
}
