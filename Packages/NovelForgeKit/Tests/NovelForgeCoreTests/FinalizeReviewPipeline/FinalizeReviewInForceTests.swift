import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// One review per attempt (G11): the job keeps the first ready one, and a duplicate another device appended later takes the author's answers with it, since an
/// answer names its revision, item and proposal, never a review (decision 4).
@Suite("Finalize review in force", TestTimeLimit.standard)
struct FinalizeReviewInForceTests {
  @Test func shouldKeepTheFirstReadyReviewOfTheJobAndCallNoModelForASecond() async throws {
    let world = try await FinalizeReviewWorld(replies: [])
    let revision = try await world.draft()
    let job = try await world.approve()
    let first = try await duplicate(world, job: job.key, revision: revision, items: [appearance()])
    #expect(try await world.run(try world.engine(), job) == .settled(.succeeded))
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.reviews().map(\.record.id) == [first])
    #expect(world.recorder.finalized == [1])
  }

  @Test func shouldAppendNothingWhenAnotherAttemptsReviewArrivedWhileThisOneRead() async throws {
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(FinalizeReviewScript.confident)])
    let revision = try await world.draft()
    let job = try await world.approve()
    let killed = try world.engine(faults: .once(at: .afterCommit(step: 0)))
    let handle = try await killed.run(job: job)
    #expect(await handle.result == .interrupted)
    killed.relinquish()
    let other = try await duplicate(world, job: job.key, revision: revision, items: [appearance()])
    let relaunched = try world.engine()
    let resumed = try await relaunched.resumeInterruptedAttempts()
    #expect(resumed.map(\.attempt) == [handle.attempt])
    for run in resumed { #expect(await run.result == .settled(.succeeded)) }
    #expect(try await world.reviews().map(\.record.id) == [other])
    #expect(world.recorder.finalized == [1])
  }

  @Test func shouldKeepTheJobsFirstReviewOverALateDuplicateAndLetALaterRunReadAgain() async throws {
    let world = try await FinalizeReviewWorld()
    let job = try await world.prepared(on: try world.engine(), autoKeep: [])
    let (store, novel) = (world.store, world.novel)
    try await store.decideFinalizeItem(novel: novel, chapter: 1, item: "promise:thread:lamp_debt", decision: .skipped, reason: "half paid")
    try await store.decideFinalizeItem(novel: novel, chapter: 1, item: "character_state:mira", decision: .kept)
    try await store.keepRoutineFinalizeItems(novel: novel, chapter: 1)
    let head = try await world.head()
    #expect(try await world.readiness() == .available([]))
    let first = try #require(try await world.reviews().first?.record)
    let moved = first.items.map { item -> StoredFinalizeItem in
      guard item.key == "character_state:mira" else { return item }
      var item = item
      item.proposed["state"] = ["entityKey": "mira", "location": "the lighthouse", "evidence": "Mira climbs the tower"]
      return item
    }
    try await duplicate(world, job: job.key, revision: head, items: moved)
    #expect(try await world.inForce().read.record.id == first.id)
    #expect(try await world.readiness() == .available([]))

    let input = reread(first)
    let rerun = try await store.writeDomain { transaction throws(DomainError) in try FinalizeReviewJobs.key(input, novel: novel, chapter: 1, run: 2) }
    let later = try await duplicate(world, job: rerun.ref.key, revision: head, items: moved)
    #expect(try await world.inForce().read.record.id == later)
    #expect(try await world.readiness() == .available([.unanswered(count: 1)]))
    #expect(try await world.items(.consequential).first?.decision == .skipped)
  }

  private func reread(_ review: FinalizeReviewRecord) -> FinalizeReviewJobInput {
    FinalizeReviewJobInput(revision: review.draftRevision, sourceHash: review.sourceHash, plan: review.planHash)
  }

  @discardableResult
  private func duplicate(_ world: FinalizeReviewWorld, job: EntityKey, revision: String, items: [StoredFinalizeItem]) async throws -> UUID {
    world.base.clock.advance(1)
    let attempt = try AttemptID(UUID.v7(at: world.base.clock.now))
    let review = try FinalizeReviewRecord(
      attempt: attempt, job: job, novel: world.novel, chapter: 1, draftRevision: revision, sourceHash: hashReviewedBody(FinalizeReviewScript.prose),
      planHash: nil, isolated: false, items: items)
    try await Projection.write(world.store) { transaction in _ = try review.append(in: &transaction) }
    return review.id
  }

  private func appearance() -> StoredFinalizeItem {
    StoredFinalizeItem(
      key: "appearance:mira", position: 0, category: .known(.appearance), triage: .known(.routine), basis: .known(.observed), subject: "mira",
      claim: "mira appears in this chapter", proposed: ["category": "appearance", "entityKey": "mira"], autoDecision: .known(.kept))
  }
}

/// The pipeline killed at every runner boundary resumes, as a relaunch does, to one review and one finalize.
@Suite("Finalize review crashes", TestTimeLimit.standard)
struct FinalizeReviewCrashTests {
  static let points: [AttemptRunner.Faults.Point] =
    (0..<4).map { .committed(write: $0) } + [.call(step: 0)] + (0..<3).flatMap { [AttemptRunner.Faults.Point.beforeCommit(step: $0), .afterCommit(step: $0)] }

  @Test(arguments: points)
  func shouldResumeAKilledReviewToOneReadAndOneFinalize(_ point: AttemptRunner.Faults.Point) async throws {
    let reply = FinalizeReviewScript.reply(FinalizeReviewScript.confident)
    let world = try await FinalizeReviewWorld(replies: [reply, reply])
    try await world.draft()
    let job = try await world.approve()
    let killed = try world.engine(finalizing: FinalizeReviewPipeline.commit, faults: .once(at: point))
    let handle = try await killed.run(job: job)
    #expect(await handle.result == .interrupted)
    killed.relinquish()

    world.base.clock.advance(5)
    let relaunched = try world.engine(finalizing: FinalizeReviewPipeline.commit)
    let resumed = try await relaunched.resumeInterruptedAttempts()
    let finished = [AttemptRunner.Faults.Point.afterCommit(step: 2), .committed(write: 3)].contains(point)
    #expect(resumed.map(\.attempt) == (finished ? [] : [handle.attempt]))
    for run in resumed { #expect(await run.result == .settled(.succeeded)) }

    #expect(try await world.reviews().count == 1)
    let novel = world.novel
    #expect(try await world.store.writeDomain { transaction throws(DomainError) in try transaction.isFinal(novel: novel, chapter: 1) })
    #expect(try await world.base.status(job) == .succeeded(handle.attempt))
    #expect(world.provider.requests.count == ([.call(step: 0), .beforeCommit(step: 0)].contains(point) ? 2 : 1))
  }
}
