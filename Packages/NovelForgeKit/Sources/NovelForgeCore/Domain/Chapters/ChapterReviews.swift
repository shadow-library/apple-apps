import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText

public enum ChapterReviewError: ShadowError, Equatable {
  case reviewNotFound(UUID)
  case findingNotFound(String)
  case reviewStale
  case dismissNeedsReason
  case overrideNotBlocking
  case nothingToReview(Int)
  case generating(Int)
  case runsAsJob(ChapterReviewKind)
  case record(ReviewRecordError)
  case domain(DomainError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .reviewNotFound: "REV_001"
    case .findingNotFound: "REV_002"
    case .reviewStale: "REV_003"
    case .dismissNeedsReason: "REV_004"
    case .overrideNotBlocking: "REV_005"
    case .nothingToReview: "REV_006"
    case .generating: "REV_007"
    case .runsAsJob: "chapter_review.runs_as_job"
    case .record(let error): error.code
    case .domain(let error): error.code
    case .store(let error): error.code
    }
  }

  // apps/novel-forge-server/src/classes/app-error-code.ts:251-257
  public var errorDescription: String? {
    switch self {
    case .reviewNotFound: "Review not found"
    case .findingNotFound: "That finding is not part of this review"
    case .reviewStale: "The chapter changed after this review — review the current text again before answering its findings"
    case .dismissNeedsReason: "Say why you are dismissing this finding"
    case .overrideNotBlocking: "Only a blocking finding can be overridden"
    case .nothingToReview(let chapter): "Chapter \(chapter) has no prose to review yet"
    case .generating(let chapter): "Chapter \(chapter) is still being written — review it once the draft is ready"
    case .runsAsJob(let kind): "A \(kind.rawValue) review runs as a job."
    case .record(let error): error.errorDescription
    case .domain(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: ChapterReviewError, right: ChapterReviewError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}

/// The text a review reads: the draft at a revision, or the final chapter's text as amendments left it under the revision its canon took
/// (apps/novel-forge-server/src/modules/review/review-records.ts:88-122). `isolated` is the prose's own flag.
struct ReviewSource: Codable, Equatable, Sendable {
  var draftRevision: String?
  var body: String
  var isolated: Bool
  var final: Bool

  var bodyHash: String { hashReviewedBody(body) }

  var reviewed: ReviewedText { ReviewedText(draftRevision: draftRevision, bodyHash: bodyHash) }
}

public struct ChapterReviewView: Sendable, Equatable {
  public let review: ChapterReviewRecord
  public let clock: HLCTimestamp
  /// The chapter's text moved past what the review read, so its findings can no longer be answered.
  public let stale: Bool
  public let remedies: [String: ReviewRemedy]
  public let openFindings: Int
  public let openBlocking: Int
}

/// apps/novel-forge-server/src/modules/review/chapter-review.service.ts:161-174: the newest review of each kind, then the chapter's last 50, newest first.
public struct ChapterReviewList: Sendable, Equatable {
  public let chapter: Int
  public let currentRevision: String?
  public let latest: [ChapterReviewView]
  public let history: [ChapterReviewView]
  public let unreadable: Int
}

/// Reviews of a chapter as it stands, each bound to the text it read; they never edit prose. Whether an open blocking finding of the latest judge review
/// holds the chapter is the lifecycle's derivation, which reads these records, so no write here touches the draft (chapter-review.service.ts:480-521).
public enum ChapterReviews {
  // apps/novel-forge-server/src/modules/review/review-records.ts:9
  public static let kindOrder: [ChapterReviewKind] = [.judge, .editorial, .mechanics, .readability]

  // apps/novel-forge-server/src/modules/review/chapter-review.service.ts:108-110
  static let modelKinds: Set<ChapterReviewKind> = [.judge, .editorial]
  static let historyLimit = 50
  static let mechanicalPriorWindow = 10

  /// The chapter's reviewable text now; nil when it has none or only blank prose.
  static func source<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws(ChapterReviewError) -> ReviewSource? {
    if let final = try finalSource(novel: novel, chapter: chapter, in: transaction) { return final }
    let ref = try domain { () throws(DomainError) in try ChapterRefs.draft(novel: novel, chapter: chapter) }
    let entry = try readable(try stored { () throws(StoreError) in try DraftRecord.read(ref, in: transaction) }, ref: ref)
    guard let entry, !entry.isRemoved, !entry.record.content.body.jsTrim().isEmpty else { return nil }
    let history = try stored { () throws(StoreError) in try DraftRecord.history(ref, in: transaction) }.history
    guard let head = history?.head else { throw .domain(.unreadable(ref)) }
    return ReviewSource(draftRevision: head, body: entry.record.content.body, isolated: entry.record.content.isolated, final: false)
  }

  /// The text a job names: that draft revision, or the final chapter's text once the chapter is final.
  static func source<Transaction: StateReading & ~Copyable>(
    novel: UUID, chapter: Int, revision: String?, in transaction: borrowing Transaction
  ) throws(ChapterReviewError) -> ReviewSource {
    if let final = try finalSource(novel: novel, chapter: chapter, in: transaction) { return final }
    guard let revision else { throw .nothingToReview(chapter) }
    let ref = try domain { () throws(DomainError) in try ChapterRefs.draft(novel: novel, chapter: chapter) }
    let history = try stored { () throws(StoreError) in try DraftRecord.history(ref, in: transaction) }.history
    guard let entry = history?.revisions.first(where: { $0.id.utf8.elementsEqual(revision.utf8) }) else {
      throw .domain(.versionNotFound(chapter: chapter, revision: revision))
    }
    guard let content = entry.body.body else { throw .domain(.versionUnreadable(chapter: chapter, revision: revision)) }
    guard !content.body.jsTrim().isEmpty else { throw .nothingToReview(chapter) }
    return ReviewSource(draftRevision: revision, body: content.body, isolated: content.isolated, final: false)
  }

  private static func finalSource<Transaction: StateReading & ~Copyable>(
    novel: UUID, chapter: Int, in transaction: borrowing Transaction
  ) throws(ChapterReviewError) -> ReviewSource? {
    let ref = try domain { () throws(DomainError) in try ChapterRefs.final(novel: novel, chapter: chapter) }
    guard let entry = try readable(try stored { () throws(StoreError) in try FinalChapterRecord.read(ref, in: transaction) }, ref: ref) else { return nil }
    let record = entry.record
    guard !record.text.body.jsTrim().isEmpty else { throw .nothingToReview(chapter) }
    return ReviewSource(draftRevision: record.canon.draftRevision, body: record.text.body, isolated: record.canon.isolated, final: true)
  }

  /// The chapter plan's head, which carries the chapter's content mode (chapter-route.ts:34).
  static func plan<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws(ChapterReviewError) -> ChapterPlanContent? {
    let ref = try domain { () throws(DomainError) in try ChapterRefs.plan(novel: novel, chapter: chapter) }
    guard let entry = try readable(try stored { () throws(StoreError) in try ChapterPlanRecord.read(ref, in: transaction) }, ref: ref), !entry.isRemoved else {
      return nil
    }
    return entry.record.content
  }

  /// Whether a generate job for the chapter is queued or running; both count, so the answer does not depend on `now` (generation.service.ts:242-243).
  static func isGenerating(novel: UUID, chapter: Int, at now: Date, in transaction: ReadTransaction) throws(ChapterReviewError) -> Bool {
    let activity = try stored { () throws(StoreError) in
      try JobActivity.load(JobActivityQuery(novel: novel, now: LeaseInstant(date: now, source: .device)), in: transaction)
    }
    guard let generating = activity.generating.value else { throw .domain(.lifecycleUnavailable(chapter)) }
    return generating.contains(chapter)
  }

  /// chapter-review.service.ts:410-415.
  static func reviewable(novel: UUID, chapter: Int, at now: Date, in transaction: ReadTransaction) throws(ChapterReviewError) -> ReviewSource {
    guard let source = try source(novel: novel, chapter: chapter, in: transaction) else { throw .nothingToReview(chapter) }
    if !source.final, try isGenerating(novel: novel, chapter: chapter, at: now, in: transaction) { throw .generating(chapter) }
    return source
  }

  /// Whether a review of `source` quotes prose standard models must not read: the prose is isolated, or the chapter's mode or the run made it unrestricted
  /// (chapter-review.service.ts:261, review-records.ts:62). A plan mode this version cannot read counts as unrestricted.
  static func isolated(_ source: ReviewSource, plan: ChapterPlanContent?, unrestricted: Bool) -> Bool {
    guard !unrestricted, !source.isolated else { return true }
    switch plan?.contentMode {
    case nil, .known(.standard)?: return false
    case .known(.unrestricted)?, .unknown?: return true
    }
  }

  /// chapter-review.service.ts:443-468: the newest review that raised a finding decides whether the author's answer to it still stands.
  static func settled<Transaction: StateReading & ~Copyable>(
    novel: UUID, chapter: Int, kind: ChapterReviewKind, text: ReviewedText, in transaction: borrowing Transaction
  ) throws(ChapterReviewError) -> [SettledFinding] {
    let reviews = try stored { () throws(StoreError) in try ChapterReviewRecord.listing(novel: novel, chapter: chapter, in: transaction) }.entries.reversed().filter {
      $0.record.reviewKind == .known(kind) && !ReviewFindings.isStale(ReviewedText(draftRevision: $0.record.draftRevision, bodyHash: $0.record.bodyHash), current: text)
    }
    var decided = Set<String>()
    var settled: [SettledFinding] = []
    for entry in reviews {
      let review = entry.record
      for finding in review.findings where decided.insert(finding.fingerprint).inserted {
        guard let remedy = try remedy(of: review, finding: finding.id, in: transaction) else { continue }
        settled.append(SettledFinding(fingerprint: finding.fingerprint, action: remedy.action, reason: remedy.reason, text: finding.text))
      }
    }
    return settled
  }

  private static func remedy<Transaction: StateReading & ~Copyable>(
    of review: ChapterReviewRecord, finding: String, in transaction: borrowing Transaction
  ) throws(ChapterReviewError) -> ReviewRemedy? {
    let ref = ReviewRemedyRecord.ref(novel: review.novel, review: review.id, finding: finding)
    return try readable(try stored { () throws(StoreError) in try ReviewRemedyRecord.read(ref, in: transaction) }, ref: ref)?.record.remedy
  }

  private static func remedies<Transaction: StateReading & ~Copyable>(of review: ChapterReviewRecord, in transaction: borrowing Transaction) throws(ChapterReviewError)
    -> [ReviewRemedyRecord]
  {
    var records: [ReviewRemedyRecord] = []
    for finding in review.findings {
      guard let remedy = try remedy(of: review, finding: finding.id, in: transaction) else { continue }
      records.append(ReviewRemedyRecord(novel: review.novel, review: review.id, finding: finding.id, remedy: remedy))
    }
    return records
  }

  /// Appends the review once: a review already stored under `id` stands and false is returned. The author's answers to the same findings on the same text
  /// carry onto it, read in this transaction and written before the append, so the review is never seen without them (chapter-review.service.ts:252-275,
  /// 470-478).
  @discardableResult
  static func append(
    _ outcome: ReviewOutcome, kind: ChapterReviewKind, novel: UUID, chapter: Int, source: ReviewSource, isolated: Bool, id: UUID, job: EntityKey? = nil,
    attempt: AttemptID? = nil, calls: [UUID]? = nil, in transaction: inout WriteTransaction
  ) throws(ChapterReviewError) -> Bool {
    guard try stored({ () throws(StoreError) in try ChapterReviewRecord.read(id: id, in: transaction) }) == .absent else { return false }
    let record: ChapterReviewRecord
    do throws(ReviewRecordError) {
      record = try ChapterReviewRecord(
        id: id, novel: novel, chapter: chapter, reviewKind: .known(kind), draftRevision: source.draftRevision, bodyHash: source.bodyHash,
        disposition: .known(outcome.disposition), verdict: outcome.verdict, findings: outcome.findings, isolated: isolated, note: outcome.note, checked: outcome.checked,
        job: job, attempt: attempt, calls: calls)
    } catch {
      throw .record(error)
    }
    let settled = try settled(novel: novel, chapter: chapter, kind: kind, text: source.reviewed, in: transaction)
    let byFingerprint = Dictionary(settled.map { ($0.fingerprint, $0) }) { first, _ in first }
    try stored { () throws(StoreError) in
      for finding in record.findings {
        guard let prior = byFingerprint[finding.fingerprint] else { continue }
        _ = try ReviewRemedyRecord.set(
          novel: novel, review: id, finding: finding.id, ReviewRemedy(action: prior.action, fingerprint: finding.fingerprint, reason: prior.reason), in: &transaction)
      }
      _ = try record.append(in: &transaction)
    }
    return true
  }

  /// The quick kinds, which call no model, on any device (chapter-review.service.ts:143-144, 244-245). Returns the stored review's id.
  static func runDirect(
    _ kind: ChapterReviewKind, novel: UUID, chapter: Int, source: ReviewSource, unrestricted: Bool, id: UUID, in transaction: inout WriteTransaction
  ) throws(ChapterReviewError) -> UUID {
    guard !modelKinds.contains(kind) else { throw .runsAsJob(kind) }
    try domain { () throws(DomainError) in try transaction.requireNovel(novel) }
    let plan = try plan(novel: novel, chapter: chapter, in: transaction)
    let outcome =
      kind == .mechanics
      ? ReviewFindings.mechanicsOutcome(
        body: source.body, priorBodies: try priorBodies(novel: novel, chapter: chapter, in: transaction), target: try wordTarget(novel: novel, in: transaction))
      : ReviewFindings.readabilityOutcome(body: source.body)
    let isolated = isolated(source, plan: plan, unrestricted: unrestricted)
    try append(outcome, kind: kind, novel: novel, chapter: chapter, source: source, isolated: isolated, id: id, in: &transaction)
    return id
  }

  /// chapter-review.service.ts:386-395: the last ten earlier final chapters that are not isolated, newest first, then those with prose.
  private static func priorBodies(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(ChapterReviewError) -> [String] {
    var bodies: [String] = []
    for earlier in stride(from: chapter - 1, through: 1, by: -1) where bodies.count < mechanicalPriorWindow {
      let ref = try domain { () throws(DomainError) in try ChapterRefs.final(novel: novel, chapter: earlier) }
      guard let record = try stored({ () throws(StoreError) in try FinalChapterRecord.read(ref, in: transaction) }).entry?.record, !record.canon.isolated else { continue }
      bodies.append(record.text.body)
    }
    return bodies.filter { !$0.isEmpty }
  }

  private static func wordTarget(novel: UUID, in transaction: borrowing WriteTransaction) throws(ChapterReviewError) -> ResolvedWordTarget {
    let novelRecord = try stored { () throws(StoreError) in try NovelRecord.read(id: novel, in: transaction) }.entry?.record
    return ResolvedWordTarget.resolve(novelRecord?.wordTarget)
  }

  /// chapter-review.service.ts:181-200. An answer equal to the stored one is not written again, so a carried remedy keeps the clock it had when its review
  /// was recorded and an approval bound to that moment is not reset by a repeated answer.
  static func setRemedy(
    novel: UUID, chapter: Int, review id: UUID, finding findingID: String, action: ReviewRemedyAction, reason: String?, in transaction: inout WriteTransaction
  ) throws(ChapterReviewError) {
    let (review, finding) = try answerable(novel: novel, chapter: chapter, review: id, finding: findingID, in: transaction)
    let reason = reason?.jsTrim().nonEmpty
    if action == .dismissed, reason == nil { throw .dismissNeedsReason }
    if action == .overridden, finding.severity != .known(.blocking) { throw .overrideNotBlocking }
    let remedy = ReviewRemedy(action: .known(action), fingerprint: finding.fingerprint, reason: reason)
    guard try self.remedy(of: review, finding: finding.id, in: transaction) != remedy else { return }
    try stored { () throws(StoreError) in _ = try ReviewRemedyRecord.set(novel: novel, review: id, finding: finding.id, remedy, in: &transaction) }
  }

  /// chapter-review.service.ts:202-212: the finding is open again and stops carrying to later reviews.
  static func clearRemedy(novel: UUID, chapter: Int, review id: UUID, finding findingID: String, in transaction: inout WriteTransaction) throws(ChapterReviewError) {
    let (review, finding) = try answerable(novel: novel, chapter: chapter, review: id, finding: findingID, in: transaction)
    guard try remedy(of: review, finding: finding.id, in: transaction) != nil else { return }
    try stored { () throws(StoreError) in _ = try ReviewRemedyRecord.clear(novel: novel, review: id, finding: finding.id, in: &transaction) }
  }

  // apps/novel-forge-server/src/modules/review/chapter-review.service.ts:421-441
  private static func answerable(
    novel: UUID, chapter: Int, review id: UUID, finding findingID: String, in transaction: borrowing WriteTransaction
  ) throws(ChapterReviewError) -> (ChapterReviewRecord, ReviewFinding) {
    guard let review = try stored({ () throws(StoreError) in try ChapterReviewRecord.read(id: id, in: transaction) }).entry?.record, review.novel == novel,
      review.chapter == chapter
    else { throw .reviewNotFound(id) }
    let normalized = findingID.precomposedStringWithCanonicalMapping
    guard let finding = review.findings.first(where: { $0.id.utf8.elementsEqual(normalized.utf8) }) else { throw .findingNotFound(findingID) }
    let current = try source(novel: novel, chapter: chapter, in: transaction)
    guard !ReviewFindings.isStale(ReviewedText(draftRevision: review.draftRevision, bodyHash: review.bodyHash), current: current?.reviewed) else { throw .reviewStale }
    return (review, finding)
  }

  public static func list<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws(ChapterReviewError)
    -> ChapterReviewList
  {
    let listing = try stored { () throws(StoreError) in try ChapterReviewRecord.listing(novel: novel, chapter: chapter, in: transaction) }
    let current = try source(novel: novel, chapter: chapter, in: transaction)
    var history: [ChapterReviewView] = []
    for entry in listing.entries.reversed().prefix(historyLimit) {
      let review = entry.record
      let remedies = try remedies(of: review, in: transaction)
      let open = ReviewFindings.open(review.findings, remedies: remedies)
      history.append(
        ChapterReviewView(
          review: review, clock: entry.clock,
          stale: ReviewFindings.isStale(ReviewedText(draftRevision: review.draftRevision, bodyHash: review.bodyHash), current: current?.reviewed),
          remedies: Dictionary(remedies.compactMap { record in record.remedy.map { (record.finding, $0) } }) { first, _ in first }, openFindings: open.count,
          openBlocking: open.filter { $0.severity == .known(.blocking) }.count))
    }
    let latest = kindOrder.compactMap { kind in history.first { $0.review.reviewKind == .known(kind) } }
    return ChapterReviewList(chapter: chapter, currentRevision: current?.draftRevision, latest: latest, history: history, unreadable: listing.unreadable)
  }

  static func stored<T>(_ body: () throws(StoreError) -> T) throws(ChapterReviewError) -> T {
    do {
      return try body()
    } catch {
      throw .store(error)
    }
  }

  static func domain<T>(_ body: () throws(DomainError) -> T) throws(ChapterReviewError) -> T {
    do {
      return try body()
    } catch {
      throw .domain(error)
    }
  }

  private static func readable<Record: Sendable & Equatable>(_ reading: RecordReading<Record>, ref: EntityRef) throws(ChapterReviewError) -> RecordEntry<Record>? {
    try domain { () throws(DomainError) in try NovelForgeCore.readable(reading, ref: ref) }
  }
}

extension VaultStore {
  /// A mechanics or readability review of the chapter as it stands; a judge or editorial review is requested through `JobEngine.requestReview`.
  @discardableResult
  public func reviewChapter(novel: UUID, chapter: Int, kind: ChapterReviewKind, unrestricted: Bool = false, id: UUID = UUID()) async throws(ChapterReviewError) -> UUID {
    guard !ChapterReviews.modelKinds.contains(kind) else { throw .runsAsJob(kind) }
    let now = wallClock()
    let source = try await reviewRead { transaction throws(ChapterReviewError) in try ChapterReviews.reviewable(novel: novel, chapter: chapter, at: now, in: transaction) }
    return try await reviewWrite { transaction throws(ChapterReviewError) in
      guard try ChapterReviews.source(novel: novel, chapter: chapter, in: transaction) == source else { throw .reviewStale }
      return try ChapterReviews.runDirect(kind, novel: novel, chapter: chapter, source: source, unrestricted: unrestricted, id: id, in: &transaction)
    }
  }

  public func setReviewRemedy(
    novel: UUID, chapter: Int, review: UUID, finding: String, action: ReviewRemedyAction, reason: String? = nil
  ) async throws(ChapterReviewError) {
    try await reviewWrite { transaction throws(ChapterReviewError) in
      try ChapterReviews.setRemedy(novel: novel, chapter: chapter, review: review, finding: finding, action: action, reason: reason, in: &transaction)
    }
  }

  public func clearReviewRemedy(novel: UUID, chapter: Int, review: UUID, finding: String) async throws(ChapterReviewError) {
    try await reviewWrite { transaction throws(ChapterReviewError) in
      try ChapterReviews.clearRemedy(novel: novel, chapter: chapter, review: review, finding: finding, in: &transaction)
    }
  }

  public func chapterReviews(novel: UUID, chapter: Int) async throws(ChapterReviewError) -> ChapterReviewList {
    try await reviewRead { transaction throws(ChapterReviewError) in try ChapterReviews.list(novel: novel, chapter: chapter, in: transaction) }
  }

  func reviewRead<T: Sendable>(_ body: @Sendable (ReadTransaction) throws(ChapterReviewError) -> T) async throws(ChapterReviewError) -> T {
    do {
      return try await read { transaction in try body(transaction) }
    } catch {
      throw ChapterReviewError(error)
    }
  }

  func reviewWrite<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(ChapterReviewError) -> T) async throws(ChapterReviewError) -> T {
    do {
      return try await write { transaction in try body(&transaction) }
    } catch {
      throw ChapterReviewError(error)
    }
  }
}

extension ChapterReviewError {
  init(_ error: StoreError) {
    guard case .aborted(let cause) = error else {
      self = .store(error)
      return
    }
    switch cause {
    case let cause as ChapterReviewError: self = cause
    case let cause as DomainError: self = .domain(cause)
    default: self = .store(error)
    }
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
