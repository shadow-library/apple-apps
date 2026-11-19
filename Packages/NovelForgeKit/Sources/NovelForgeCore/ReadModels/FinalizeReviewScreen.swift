import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

public struct FinalizeReviewScreenQuery: Sendable, Hashable {
  public let novel: UUID
  public let chapter: Int

  public init(novel: UUID, chapter: Int) {
    self.novel = novel
    self.chapter = chapter
  }
}

/// The finalize review dialog's read: apps/novel-forge-server/src/modules/finalize-review/finalize-review.service.ts:118-185 (presentFinalizeReview) over the
/// same chain and answers `FinalizeReadiness` gates on, the head's state when no read of it is ready as `FinalizeReviewDecisions.openReview` refuses it, and
/// for a final chapter the review its canon applied. Excerpts are withheld whenever the read or the head is isolated, whichever way isolation moved since.
public struct FinalizeReviewScreen: ReadModel {
  public struct Item: Sendable, Equatable {
    public let key: String
    /// Nil for an item this version cannot read; it can still be kept or skipped, not edited.
    public let category: FinalizeCategory?
    public let triage: FinalizeTriage
    public let basis: FinalizeBasis?
    public let flag: FinalizeFlag?
    public let subject: String
    public let claim: String
    public let evidence: String?
    public let dependents: [String]
    public let proposed: [String: JSONValue]
    public let edited: [String: JSONValue]?
    public let decision: FinalizeDecision?
    public let reason: String?
    public let autoKept: Bool
    /// Answered at an earlier revision and carried onto this read.
    public let carriedOver: Bool
    /// Answered at this revision for a proposal this read changed, so it needs the author again.
    public let reopened: Bool

    public init(
      key: String, category: FinalizeCategory?, triage: FinalizeTriage, basis: FinalizeBasis?, flag: FinalizeFlag?, subject: String, claim: String, evidence: String?,
      dependents: [String], proposed: [String: JSONValue], edited: [String: JSONValue]?, decision: FinalizeDecision?, reason: String?, autoKept: Bool,
      carriedOver: Bool, reopened: Bool
    ) {
      self.key = key
      self.category = category
      self.triage = triage
      self.basis = basis
      self.flag = flag
      self.subject = subject
      self.claim = claim
      self.evidence = evidence
      self.dependents = dependents
      self.proposed = proposed
      self.edited = edited
      self.decision = decision
      self.reason = reason
      self.autoKept = autoKept
      self.carriedOver = carriedOver
      self.reopened = reopened
    }
  }

  public struct Review: Sendable, Equatable {
    public let id: UUID
    public let revision: String
    public let isolated: Bool
    public let items: [Item]

    public init(id: UUID, revision: String, isolated: Bool, items: [Item]) {
      self.id = id
      self.revision = revision
      self.isolated = isolated
      self.items = items
    }
  }

  /// One update a set of changes keeps, as finalize applies it.
  public struct Update: Sendable, Equatable {
    public let category: FinalizeCategory?
    public let claim: String?
    public let change: [String: JSONValue]

    public init(category: FinalizeCategory?, claim: String?, change: [String: JSONValue]) {
      self.category = category
      self.claim = claim
      self.change = change
    }
  }

  /// A finalize of this chapter whose canon lost to the one that stands and that kept other updates (plan: "if two commits name different reviews, the first
  /// order wins and the app lists both sets of changes"), named by the review and kept list its refresh request recorded.
  public struct OtherSet: Sendable, Equatable {
    /// Its canon_refresh job: the losing canon.
    public let id: String
    /// What it kept, as the review it named resolves now; nil when this device cannot read that review, or the request named none.
    public let updates: [Update]?
    /// The review's answers still keep exactly what that finalize kept.
    public let exact: Bool

    public init(id: String, updates: [Update]?, exact: Bool) {
      self.id = id
      self.updates = updates
      self.exact = exact
    }
  }

  public struct Applied: Sendable, Equatable {
    /// The read the canon names, as its answers leave it; nil when this device cannot read it.
    public let review: Review?
    public let isolated: Bool
    public let kept: [Update]
    public let otherSets: [OtherSet]

    public init(review: Review?, isolated: Bool, kept: [Update], otherSets: [OtherSet]) {
      self.review = review
      self.isolated = isolated
      self.kept = kept
      self.otherSets = otherSets
    }
  }

  public enum Unavailable: Sendable, Equatable {
    /// Stored in a form this version cannot read: a newer version of the app wrote it.
    case unreadable
    /// The chapter's jobs are being rebuilt on this device.
    case rebuilding
  }

  public enum State: Sendable, Equatable {
    case noDraft
    /// The draft, the canon, a read or the chapter's jobs cannot be read on this device now.
    case unavailable(Unavailable)
    /// FRV_001: no read of the head and none asked for; approving the chapter asks for one.
    case unreviewed
    case preparing(revision: String)
    case failed(revision: String, failure: AttemptFailure?)
    /// Only other text was read: approving the head again reads it.
    case invalidated(read: String)
    case ready(Review)
    case applied(Applied)
  }

  public let state: State
  /// The routine categories later reviews keep without asking (finalize-review-items.ts:71).
  public let autoKeep: [FinalizeCategory]
  /// The head draft is isolated, or the final chapter's canon: only its author finalizes it, never its approval.
  public let isolated: Bool

  public init(state: State, autoKeep: [FinalizeCategory], isolated: Bool) {
    self.state = state
    self.autoKeep = autoKeep
    self.isolated = isolated
  }

  public static func load(_ query: FinalizeReviewScreenQuery, in transaction: ReadTransaction) throws(StoreError) -> FinalizeReviewScreen {
    let (novel, chapter) = (query.novel, query.chapter)
    let chosen = try NovelRecord.read(id: novel, in: transaction).entry?.record.autoKeep?.compactMap(\.known)
    let autoKeep = effectiveAutoKeep(chosen)
    guard let draftRef = try? DraftRecord.ref(novel: novel, chapter: chapter), let finalRef = try? FinalChapterRecord.ref(novel: novel, chapter: chapter) else {
      return FinalizeReviewScreen(state: .noDraft, autoKeep: autoKeep, isolated: false)
    }
    let unreadable = FinalizeReviewScreen(state: .unavailable(.unreadable), autoKeep: autoKeep, isolated: false)
    let listing = try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction)
    guard listing.unreadable == 0 else { return unreadable }
    let reads = listing.entries.filter { $0.record.novel == novel && $0.record.chapter == chapter }
    let jobs = try ReadFaults(novel: novel, reading: jobTables, in: transaction).section(jobTables) { () throws(StoreError) in
      try transaction.query { database in
        try JobEntry.filter(
          Column("novel") == novel && Column("chapter") == chapter
            && [NovelJobKind.finalizeReview.rawValue, NovelJobKind.canonRefresh.rawValue].contains(Column("kind"))
        ).fetchAll(database)
      }
    }
    guard let jobs = jobs.value else { return FinalizeReviewScreen(state: .unavailable(.rebuilding), autoKeep: autoKeep, isolated: false) }
    switch try FinalChapterRecord.read(finalRef, in: transaction) {
    case .unreadable: return unreadable
    case .readable(let final) where !final.isRemoved:
      let applied = try applied(final.record, reads: reads, losing: jobs, novel: novel, chapter: chapter, in: transaction)
      return FinalizeReviewScreen(state: .applied(applied), autoKeep: autoKeep, isolated: final.record.canon.isolated)
    case .readable, .absent: break
    }
    let draft: RecordEntry<DraftRecord>
    switch try DraftRecord.read(draftRef, in: transaction) {
    case .unreadable: return unreadable
    case .absent: return FinalizeReviewScreen(state: .noDraft, autoKeep: autoKeep, isolated: false)
    case .readable(let entry): draft = entry
    }
    guard !draft.isRemoved else { return FinalizeReviewScreen(state: .noDraft, autoKeep: autoKeep, isolated: false) }
    guard let head = try DraftRecord.history(draftRef, in: transaction).history?.head else { return unreadable }
    let content = draft.record.content
    let state = try open(novel: novel, chapter: chapter, head: head, content: content, reads: reads, jobs: jobs, in: transaction)
    return FinalizeReviewScreen(state: state, autoKeep: autoKeep, isolated: content.isolated)
  }

  private static let jobTables = [JobEntry.databaseTableName]

  private static func open(
    novel: UUID, chapter: Int, head: String, content: DraftContent, reads: [AppendedEntry<FinalizeReviewRecord>], jobs: [JobEntry],
    in transaction: ReadTransaction
  ) throws(StoreError) -> State {
    let chain = FinalizeReviewChain.chain(reads, head: head)
    let answers = try FinalizeReviewChain.answers(to: chain, novel: novel, chapter: chapter, in: transaction)
    if let resolved = FinalizeReviewChain.resolve(chain: chain, answers: answers) {
      guard resolved.read.record.sourceHash == hashReviewedBody(content.body) else { return .invalidated(read: resolved.read.record.draftRevision) }
      return .ready(review(resolved, answered: answers[head] ?? [:], redacted: resolved.read.record.isolated || content.isolated))
    }
    let candidates = jobs.filter { $0.kind == NovelJobKind.finalizeReview.rawValue }
    let requests = try FinalizeReviewJobs.requests(novel: novel, chapter: chapter, revision: head, among: candidates.map(\.ref), in: transaction)
    guard requests.unreadable.isEmpty else { return .unavailable(.unreadable) }
    let named = Set(requests.read)
    let entries = candidates.filter { named.contains($0.ref) }
    if entries.contains(where: { !ended($0) }) { return .preparing(revision: head) }
    if let failed = entries.max(by: { $0.requested < $1.requested }) { return .failed(revision: head, failure: failed.standing.failure) }
    guard let latest = reads.max(by: FinalizeReviewChain.precedes) else { return .unreviewed }
    return .invalidated(read: latest.record.draftRevision)
  }

  private static func review(_ resolved: FinalizeReviewChain.Resolved, answered: [String: StoredFinalizeAnswer], redacted: Bool) -> Review {
    let items = resolved.items.map { entry -> Item in
      let stored = entry.stored
      let own = answered[stored.key].flatMap { $0.auto || $0.decision.known == nil ? nil : $0 }
      guard let item = entry.item else {
        let decision = own?.decision.known ?? stored.autoDecision?.known
        return Item(
          key: stored.key, category: stored.category.known, triage: stored.triage.known ?? .consequential, basis: stored.basis.known, flag: stored.flag?.known,
          subject: stored.subject, claim: stored.claim, evidence: withheld(stored.evidence, redacted), dependents: stored.dependents ?? [],
          proposed: withheld(stored.proposed, redacted), edited: nil, decision: decision, reason: own?.reason, autoKept: own == nil && decision != nil,
          carriedOver: false, reopened: false)
      }
      return Item(
        key: item.itemKey, category: item.category, triage: item.triage, basis: item.basis, flag: item.flag, subject: item.subjectKey, claim: item.claim,
        evidence: withheld(item.evidence, redacted), dependents: item.dependents ?? [], proposed: withheld(item.proposed.json.objectValue ?? [:], redacted),
        edited: item.decision == .edited ? item.edited.flatMap { withheld($0.json.objectValue ?? [:], redacted) } : nil, decision: item.decision,
        reason: item.reason, autoKept: item.autoKept, carriedOver: item.decision != nil && !item.autoKept && own == nil, reopened: item.decision == nil && own != nil)
    }
    return Review(id: resolved.read.record.id, revision: resolved.read.record.draftRevision, isolated: redacted, items: items)
  }

  private static func applied(
    _ final: FinalChapterRecord, reads: [AppendedEntry<FinalizeReviewRecord>], losing jobs: [JobEntry], novel: UUID, chapter: Int, in transaction: ReadTransaction
  ) throws(StoreError) -> Applied {
    let canon = final.canon
    let redacted = canon.isolated || reads.contains { $0.record.isolated }
    guard let bound = canon.review else { return Applied(review: nil, isolated: redacted, kept: [], otherSets: []) }
    let resolved = try reads.first { $0.record.id == bound.id }.map { read throws(StoreError) in try resolve(read, among: reads, novel: novel, chapter: chapter, in: transaction) }
    let claims = Dictionary((resolved?.review.items ?? []).map { ($0.stored.key, $0.stored.claim) }) { first, _ in first }
    let kept = bound.kept.map { change in update(change, claim: ProposedChange(json: .object(change)).flatMap { claims[$0.itemKey] }, redacted: redacted) }
    let shown = resolved.map { review($0.review, answered: $0.answers[$0.review.read.record.draftRevision] ?? [:], redacted: redacted) }
    var seen: Set<String> = [CanonRefreshReview(bound).kept]
    var otherSets = [OtherSet]()
    let losing = jobs.filter { $0.kind == NovelJobKind.canonRefresh.rawValue && $0.fingerprint != final.canonDigest }.sorted { $0.requested < $1.requested }
    for job in losing {
      let request = try transaction.state(of: job.ref, scope: .vault).flatMap { JobRecords.reading($0, of: job.ref).record }?.request
      guard let named = request.flatMap({ CanonRefreshReview(payload: $0.payload) }) else {
        otherSets.append(OtherSet(id: job.job.rawValue, updates: nil, exact: false))
        continue
      }
      guard seen.insert(named.kept).inserted else { continue }
      guard let read = reads.first(where: { $0.record.id == named.id }) else {
        otherSets.append(OtherSet(id: job.job.rawValue, updates: nil, exact: false))
        continue
      }
      let other = try resolve(read, among: reads, novel: novel, chapter: chapter, in: transaction)
      let changes = keptChanges(other.review, answered: other.answers[read.record.draftRevision] ?? [:])
      let updates = changes.map { update($0.change, claim: $0.claim, redacted: redacted) }
      otherSets.append(OtherSet(id: job.job.rawValue, updates: updates, exact: CanonRefreshReview.fingerprint(of: changes.map(\.change)) == named.kept))
    }
    return Applied(review: shown, isolated: redacted, kept: kept, otherSets: otherSets)
  }

  /// `FinalizeReviewJobs.ended` over the job's derived row: failed or cancelled, with nothing left running and nothing succeeded.
  private static func ended(_ job: JobEntry) -> Bool {
    switch job.standing.end {
    case .cancelled: true
    case .succeeded: false
    case nil: !job.standing.isOpen
    }
  }

  /// `read` as the head's read of its revision: the chain its revision would have had with it as that revision's read.
  private static func resolve(
    _ read: AppendedEntry<FinalizeReviewRecord>, among reads: [AppendedEntry<FinalizeReviewRecord>], novel: UUID, chapter: Int, in transaction: ReadTransaction
  ) throws(StoreError) -> (review: FinalizeReviewChain.Resolved, answers: [String: [String: StoredFinalizeAnswer]]) {
    let revision = read.record.draftRevision
    let pool = reads.filter { $0.record.draftRevision != revision || $0 == read }
    let chain = FinalizeReviewChain.chain(pool, head: revision)
    let answers = try FinalizeReviewChain.answers(to: chain, novel: novel, chapter: chapter, in: transaction)
    guard let resolved = FinalizeReviewChain.resolve(chain: chain, answers: answers) else { preconditionFailure("a chain built for a read's own revision ends with it") }
    return (resolved, answers)
  }

  /// What `FinalizeReviewBinding` keeps of a review, in its order.
  private static func keptChanges(_ review: FinalizeReviewChain.Resolved, answered: [String: StoredFinalizeAnswer]) -> [(change: [String: JSONValue], claim: String)] {
    review.items.compactMap { entry in
      if let item = entry.item {
        guard item.decision == .kept || item.decision == .edited else { return nil }
        return (effectiveChange(item).json.objectValue ?? [:], item.claim)
      }
      let answer = answered[entry.stored.key]
      let decision = answer?.decision.known ?? entry.stored.autoDecision?.known
      guard decision == .kept || decision == .edited else { return nil }
      return (decision == .edited ? answer?.edit ?? entry.stored.proposed : entry.stored.proposed, entry.stored.claim)
    }
  }

  private static func update(_ change: [String: JSONValue], claim: String?, redacted: Bool) -> Update {
    Update(category: ProposedChange(json: .object(change))?.category, claim: claim, change: withheld(change, redacted))
  }

  private static func withheld(_ evidence: String?, _ redacted: Bool) -> String? {
    guard redacted else { return evidence }
    return evidence.map { _ in FinalizeReviewItem.withheldEvidence }
  }

  // apps/novel-forge-server/src/modules/ai/isolation-read-policy.ts:49,61-69
  private static func withheld(_ change: [String: JSONValue], _ redacted: Bool) -> [String: JSONValue] {
    guard redacted else { return change }
    return change.reduce(into: [:]) { result, member in
      result[member.key] = excerptFields.contains(member.key) && member.value.stringValue != nil ? .string(FinalizeReviewItem.withheldEvidence) : withheld(member.value)
    }
  }

  private static func withheld(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let members): .object(withheld(members, true))
    case .array(let values): .array(values.map(withheld))
    default: value
    }
  }

  private static let excerptFields: Set<String> = ["evidence", "excerpt", "quote"]
}
