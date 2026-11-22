import Foundation
import NovelForgeCore
import Observation
import ShadowAI
import ShadowAppShell
import ShadowJobs
import ShadowStore

/// What asking for a review did: answered at once, started here, requested for the device that runs it, or found running on another device.
nonisolated enum ReviewAsk: Sendable, Equatable {
  case reviewed
  case started
  case queued
  case elsewhere
}

@MainActor
@Observable
final class ChecksModel {
  typealias Requester = @MainActor (ChapterReviewKind, Pace?) async throws(ReviewRequestError) -> ReviewAsk

  let context: NovelContext
  let chapter: Int
  private(set) var reviews = Loadable<ChapterReviewList>.loading
  private(set) var starting: ChapterReviewKind?
  private(set) var busyFinding: String?
  private(set) var refusal: PresentedError?
  private(set) var elsewhere = false

  init(context: NovelContext, chapter: Int) {
    self.context = context
    self.chapter = chapter
  }

  func latest(_ kind: ChapterReviewKind) -> ChapterReviewView? {
    reviews.value?.latest.first { $0.review.reviewKind == .known(kind) }
  }

  func load() async {
    let (store, novel, chapter) = (context.store, context.novel, chapter)
    do throws(ChapterReviewError) {
      reviews = .loaded(try await store.chapterReviews(novel: novel, chapter: chapter))
    } catch {
      reviews = .failed(ChecksErrors.presented(error))
    }
  }

  func run(_ kind: ChapterReviewKind, pace: Pace?, runsJobs: Bool, using request: Requester) async {
    guard starting == nil else { return }
    if ChecksDisplay.isModelKind(kind), !runsJobs {
      refusal = JobsErrors.notRunningHere
      return
    }
    starting = kind
    refusal = nil
    elsewhere = false
    defer { starting = nil }
    do throws(ReviewRequestError) {
      switch try await request(kind, pace) {
      case .reviewed, .started, .queued: break
      case .elsewhere: elsewhere = true
      }
    } catch {
      refusal = ChecksErrors.presented(error)
    }
    await load()
  }

  func answer(_ review: ChapterReviewView, finding: ReviewFinding, action: ReviewRemedyAction, reason: String?) async -> Bool {
    await write(finding) { store, novel, chapter throws(ChapterReviewError) in
      try await store.setReviewRemedy(novel: novel, chapter: chapter, review: review.review.id, finding: finding.id, action: action, reason: reason)
    }
  }

  func clear(_ review: ChapterReviewView, finding: ReviewFinding) async -> Bool {
    await write(finding) { store, novel, chapter throws(ChapterReviewError) in
      try await store.clearReviewRemedy(novel: novel, chapter: chapter, review: review.review.id, finding: finding.id)
    }
  }

  private func write(_ finding: ReviewFinding, _ body: (VaultStore, UUID, Int) async throws(ChapterReviewError) -> Void) async -> Bool {
    guard busyFinding == nil else { return false }
    busyFinding = finding.id
    refusal = nil
    defer { busyFinding = nil }
    var succeeded = true
    do throws(ChapterReviewError) {
      try await body(context.store, context.novel, chapter)
    } catch {
      refusal = ChecksErrors.presented(error)
      succeeded = false
    }
    await load()
    return succeeded
  }

  /// `startsHere` is whether this device starts a review job it asks for (`JobRuntime.startsWhenAsked`); otherwise a judge or editorial review is only
  /// requested, and the quick kinds answer at once either way.
  static func requester(
    store: VaultStore, novel: UUID, chapter: Int, engine: JobEngine?, startsHere: Bool, follow: @escaping @MainActor (JobRunHandle) -> Void
  ) -> Requester {
    { kind, pace throws(ReviewRequestError) in
      guard ChecksDisplay.isModelKind(kind) else {
        do throws(ChapterReviewError) {
          _ = try await store.reviewChapter(novel: novel, chapter: chapter, kind: kind)
          return .reviewed
        } catch {
          throw .review(error)
        }
      }
      guard let engine else { throw .engine(.heldByAnotherProcess) }
      guard startsHere else {
        switch try await engine.queueReview(novel: novel, chapter: chapter, kind: kind, pace: pace) {
        case .reviewed: return .reviewed
        case .requested: return .queued
        }
      }
      switch try await engine.requestReview(novel: novel, chapter: chapter, kind: kind, pace: pace) {
      case .reviewed: return .reviewed
      case .running(let handle):
        follow(handle)
        return .started
      case .elsewhere: return .elsewhere
      }
    }
  }
}
