import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

public enum StartedReview: Sendable {
  case reviewed(UUID)
  case running(JobRunHandle)
  /// Another device's attempt of the job holds a live lease.
  case elsewhere(EntityRef)
}

public enum ReviewRequestError: ShadowError {
  case review(ChapterReviewError)
  case summary(ChapterSummaryError)
  case engine(JobEngineError)
  /// The chapter's route refused the call before anything was sent: AI_024, an unknown content mode or a hard-line refusal.
  case route(code: String, description: String?)
  case model(code: String, description: String?)

  public var code: String {
    switch self {
    case .review(let error): error.code
    case .summary(let error): error.code
    case .engine(let error): error.code
    case .route(let code, _), .model(let code, _): code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .review(let error): error.errorDescription
    case .summary(let error): error.errorDescription
    case .engine(let error): error.errorDescription
    case .route(_, let description), .model(_, let description): description
    }
  }
}

extension JobEngine {
  /// apps/novel-forge-server/src/modules/review/chapter-review.service.ts:143-154: the quick kinds answer at once; a judge or editorial review of the text as it
  /// stands is requested as a job and run here. The same text, kind, raise and pace is one job, run again once its review is stored, so asking twice while it
  /// runs runs it once.
  public func requestReview(novel: UUID, chapter: Int, kind: ChapterReviewKind, unrestricted: Bool = false, pace: Pace? = nil) async throws(ReviewRequestError)
    -> StartedReview
  {
    guard ChapterReviews.modelKinds.contains(kind) else {
      do {
        return .reviewed(try await store.reviewChapter(novel: novel, chapter: chapter, kind: kind, unrestricted: unrestricted))
      } catch {
        throw .review(error)
      }
    }
    let now = services.now()
    let (source, plan): (ReviewSource, ChapterPlanContent?)
    do {
      (source, plan) = try await store.reviewRead { transaction throws(ChapterReviewError) in
        (try ChapterReviews.reviewable(novel: novel, chapter: chapter, at: now, in: transaction), try ChapterReviews.plan(novel: novel, chapter: chapter, in: transaction))
      }
    } catch {
      throw .review(error)
    }
    do {
      _ = try ChapterCallRouter.route(
        ChapterCallSource(novel: novel, chapter: chapter, role: kind == .judge ? .judge : .review, plan: plan, isolated: source.isolated, raised: unrestricted),
        unrestrictedAvailable: services.unrestrictedAvailable)
    } catch {
      throw .route(code: error.code, description: error.errorDescription)
    }
    let payload = ReviewJobPayload(kind: kind.rawValue, revision: source.draftRevision, unrestricted: unrestricted, pace: pace)
    let request = NovelJobRequest(
      kind: .review, novel: novel, chapter: chapter, fingerprint: payload.fingerprint(source: source), payload: payload.json, rerunOnceSucceeded: true)
    do throws(JobEngineError) {
      let key = try await self.request(request)
      do throws(JobEngineError) {
        return .running(try await run(job: key.ref))
      } catch .runningElsewhere {
        return .elsewhere(key.ref)
      }
    } catch {
      throw .engine(error)
    }
  }
}

extension ReviewJobPayload {
  var json: JSONValue {
    var members: [String: JSONValue] = ["kind": .string(kind), "revision": revision.map(JSONValue.string) ?? .null, "unrestricted": .bool(unrestricted)]
    if let pace { members["pace"] = .string(pace.rawValue) }
    return .object(members)
  }
}
