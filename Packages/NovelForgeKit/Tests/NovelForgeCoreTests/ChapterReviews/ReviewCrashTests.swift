import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// The judge job killed at every runner write and around its one call; a relaunched engine resumes it to one review, stored under the attempt's id.
@Suite("Review job crashes", .timeLimit(.minutes(3)))
struct ReviewCrashTests {
  static let points: [AttemptRunner.Faults.Point] =
    (0..<3).map { .committed(write: $0) } + [.call(step: 1), .beforeCommit(step: 0), .afterCommit(step: 0), .beforeCommit(step: 1), .afterCommit(step: 1)]

  @Test(arguments: points)
  func shouldResumeAKilledJudgeJobToExactlyOneReview(_ point: AttemptRunner.Faults.Point) async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction, ReviewWorld.contradiction])
    let engine = try world.engine(.once(at: point))
    guard case .running(let handle) = try await engine.requestReview(novel: world.novel, chapter: 1, kind: .judge) else {
      Issue.record("the review did not run here")
      return
    }
    #expect(await handle.result == .interrupted)
    engine.relinquish()

    world.base.clock.advance(5)
    let relaunched = try world.engine()
    for resumed in try await relaunched.resumeInterruptedAttempts() { #expect(await resumed.result == .settled(.succeeded)) }

    let history = try await world.reviews().history
    #expect(history.count == 1)
    let review = try #require(history.first?.review)
    #expect(review.id == handle.attempt.uuid && review.disposition == .known(.blocking))
    let attempt = try await world.base.attempt(handle.attempt)
    #expect(attempt.outcome == .succeeded)
    #expect(Set(review.calls ?? []).isSubset(of: Set(attempt.calls)) && review.calls?.isEmpty == false)
    #expect(try await world.base.status(handle.job) == .succeeded(handle.attempt))
  }
}
