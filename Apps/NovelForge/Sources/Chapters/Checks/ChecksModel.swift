import Foundation
import NovelForgeCore
import Observation
import ShadowAI
import ShadowJobs
import ShadowStore

@MainActor
@Observable
final class ChecksModel {
  typealias Requester = @MainActor (ChapterReviewKind, Pace?) async throws(ReviewRequestError) -> StartedReview

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
      case .reviewed: break
      case .running: break
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

  static func requester(store: VaultStore, novel: UUID, chapter: Int, engine: JobEngine?, follow: @escaping @MainActor (JobRunHandle) -> Void) -> Requester {
    { kind, pace throws(ReviewRequestError) in
      guard ChecksDisplay.isModelKind(kind) else {
        do throws(ChapterReviewError) {
          return .reviewed(try await store.reviewChapter(novel: novel, chapter: chapter, kind: kind))
        } catch {
          throw .review(error)
        }
      }
      guard let engine else { throw .engine(.heldByAnotherProcess) }
      let started = try await engine.requestReview(novel: novel, chapter: chapter, kind: kind, pace: pace)
      if case .running(let handle) = started { follow(handle) }
      return started
    }
  }
}
