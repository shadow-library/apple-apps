import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

public enum CanonRefreshRequestError: ShadowError {
  case notFinal(chapter: Int)
  case canonUnreadable(chapter: Int)
  case engine(JobEngineError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .notFinal: "canon_refresh.not_final"
    case .canonUnreadable: "canon_refresh.canon_unreadable"
    case .engine(let error): error.code
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notFinal(let chapter): "Chapter \(chapter) is not final, so the Story Bible has nothing to be refreshed against."
    case .canonUnreadable(let chapter): "Chapter \(chapter)'s final text cannot be read on this device."
    case .engine(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }
}

/// What a canon refresh reads: the chapter its target names and the canon it was asked for, whose digest is the job's fingerprint (orchestrator decision 8), so
/// finalizing a chapter is one refresh however often it is asked for, and a canon another device finalized first is another job. The payload is the finalize
/// commit's `{chapter, canon}`; a job whose payload names no canon reads it from its fingerprint.
struct CanonRefreshJobInput: Sendable, Equatable {
  let chapter: Int
  let canonDigest: String

  private enum Member: String {
    case chapter
    case canon
  }

  init(chapter: Int, canonDigest: String) {
    self.chapter = chapter
    self.canonDigest = canonDigest
  }

  init(job: JobRecord, chapter: Int) {
    let named = job.request.payload.objectValue?[Member.canon.rawValue]?.stringValue
    self.init(chapter: chapter, canonDigest: named ?? job.request.key.fingerprint)
  }

  var json: JSONValue { [Member.chapter.rawValue: .int(Int64(chapter)), Member.canon.rawValue: .string(canonDigest)] }

  var fingerprint: String { canonDigest }
}

/// The finalize review a commit applied, beside its canon in the refresh request: two devices can finalize a chapter apart, and the canon that loses leaves only
/// its refresh request behind, so this is how the app lists the updates it would have kept (plan, "Finalize commit"). `kept` is `fingerprint(of:)` of
/// `CanonReview.kept`.
struct CanonRefreshReview: Sendable, Equatable {
  let id: UUID
  let kept: String

  private enum Member: String {
    case review
    case kept
  }

  init(id: UUID, kept: String) {
    self.id = id
    self.kept = kept
  }

  init(_ review: CanonReview) {
    self.init(id: review.id, kept: Self.fingerprint(of: review.kept))
  }

  init?(payload: JSONValue) {
    guard let members = payload.objectValue, let id = members[Member.review.rawValue]?.stringValue.flatMap(UUID.init(uuidString:)),
      let kept = members[Member.kept.rawValue]?.stringValue
    else { return nil }
    self.init(id: id, kept: kept)
  }

  static func fingerprint(of kept: [[String: JSONValue]]) -> String {
    sha256Hex(String(decoding: CanonicalJSON.encode(.array(kept.map(JSONValue.object))), as: UTF8.self))
  }

  func adding(to payload: JSONValue) -> JSONValue {
    var members = payload.objectValue ?? [:]
    members[Member.review.rawValue] = .string(id.lowercasedString)
    members[Member.kept.rawValue] = .string(kept)
    return .object(members)
  }
}

/// The canon_refresh jobs of a chapter (generation.service.ts:583-602 queues one after a finalize), requested as `JobEngine.request` does: the same canon is one
/// job, and a cancelled one is asked for again as its next run.
enum CanonRefreshJobs {
  static func key(_ input: CanonRefreshJobInput, novel: UUID, chapter: Int, run: Int) throws(DomainError) -> JobKey {
    do throws(JobKeyError) {
      return try JobKey(
        scope: NovelJobAddress.scope(of: novel), kind: NovelJobKind.canonRefresh.rawValue, target: NovelJobAddress.target(chapter: chapter),
        fingerprint: input.fingerprint, run: run)
    } catch {
      throw .store(.invalidChange(error.errorDescription ?? error.code))
    }
  }

  /// For the finalize commit, in its transaction; fails closed on a job record of the canon this version cannot read.
  @discardableResult
  static func request(
    novel: UUID, chapter: Int, canonDigest: String, review: CanonRefreshReview? = nil, origin: JSONValue = .null, requester: ReplicaID,
    in transaction: inout WriteTransaction
  ) throws(DomainError) -> JobKey {
    let input = CanonRefreshJobInput(chapter: chapter, canonDigest: canonDigest)
    var run = 1
    while true {
      let ref = try key(input, novel: novel, chapter: chapter, run: run).ref
      guard try storeCall({ () throws(StoreError) in try transaction.state(of: ref) }) != nil else { break }
      run += 1
    }
    if run > 1 {
      let ref = try key(input, novel: novel, chapter: chapter, run: run - 1).ref
      if let highest = try jobs({ () throws(JobRecordError) in try JobSnapshot.load(ref, in: transaction) }), !cancelled(highest) { return highest.job.request.key }
    }
    let key = try key(input, novel: novel, chapter: chapter, run: run)
    _ = try jobs { () throws(JobRecordError) in
      try JobRecords.request(JobRequest(key: key, payload: review?.adding(to: input.json) ?? input.json, origin: origin, replica: requester), in: &transaction)
    }
    return key
  }

  private static func jobs<T>(_ body: () throws(JobRecordError) -> T) throws(DomainError) -> T {
    do {
      return try body()
    } catch {
      switch error {
      case .jobUnreadable(let ref, _), .attemptUnreadable(let ref, _): throw .unreadable(ref)
      case .store(let error): throw .store(error)
      default: throw .store(.invalidChange(error.errorDescription ?? error.code))
      }
    }
  }

  /// `JobStatus`'s cancelled, which no lease decides: nothing succeeded and the cancel was asked for or an attempt ended cancelled.
  private static func cancelled(_ snapshot: JobSnapshot) -> Bool {
    guard !snapshot.attempts.contains(where: { $0.outcome == .succeeded }) else { return false }
    return snapshot.job.cancel == .requested || snapshot.attempts.contains { $0.outcome == .cancelled }
  }
}

extension JobEngine {
  /// Requests the Story Bible refresh of a final chapter's canon as it stands; the same canon answers its job, run or not. The job is only requested: the
  /// caller runs it.
  @concurrent
  public func requestCanonRefresh(novel: UUID, chapter: Int) async throws(CanonRefreshRequestError) -> JobKey {
    guard chapter >= 1 else { throw .notFinal(chapter: chapter) }
    let digest: String?
    do {
      digest = try await store.read { transaction in try RefreshRecords.canonDigest(novel: novel, chapter: chapter, in: transaction) }
    } catch {
      guard case CanonRefreshError.canonUnreadable = PlanCall.unwrapped(error) else { throw .store(error) }
      throw .canonUnreadable(chapter: chapter)
    }
    guard let digest else { throw .notFinal(chapter: chapter) }
    let input = CanonRefreshJobInput(chapter: chapter, canonDigest: digest)
    do {
      return try await request(NovelJobRequest(kind: .canonRefresh, novel: novel, chapter: chapter, fingerprint: input.fingerprint, payload: input.json))
    } catch {
      throw .engine(error)
    }
  }
}
