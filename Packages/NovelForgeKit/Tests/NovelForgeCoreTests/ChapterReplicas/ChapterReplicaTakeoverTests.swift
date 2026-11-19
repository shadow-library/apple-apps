import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// How replica 0's attempt is overtaken once its lease lapsed and replica 1 ran the job by hand.
enum Takeover: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// Its call is still in flight when replica 1's result arrives.
  case inFlight
  /// It was ended as a crash ends it and resumes after replica 1's result arrived.
  case resumedAfterSync
  /// It resumes before replica 1's result arrives and finishes, so its writes land after replica 1's.
  case resumedApart

  var testDescription: String { rawValue }
}

/// A device's lease lapses mid-run (the Mac slept) and the other device takes the job over with Run here. Both clocks move on by the lease and more, the
/// lapsed device's furthest, so a write it makes after resuming is the last writer (plan, Leases, stopping and resuming; Why a duplicate attempt is safe).
@Suite("Chapter replicas: Run here after a lease lapsed", TestTimeLimit.standard)
struct ChapterReplicaTakeoverTests {
  private static let lapse = 420

  private static func expectRefusedHere(_ device: ChapterDevice, job: EntityRef, leader: AttemptID, on replica: ReplicaID) async throws {
    do {
      _ = try await device.engine.runHere(job: job)
      Issue.record("Run here started beside a live lease")
    } catch {
      guard case JobEngineError.runningElsewhere(let attempt, let elsewhere) = error else { throw error }
      #expect(attempt == leader && elsewhere == replica)
    }
  }

  @Test(arguments: ChapterStage.allCases, Takeover.allCases)
  func shouldApplyOneResultWhenTheOtherDeviceRunsTheJobHereAfterTheLeaseLapsed(stage: ChapterStage, takeover: Takeover) async throws {
    let pair = try await ChapterReplicas.make(seed: 0x34C0 + UInt64(stage.ordinal * 3 + (Takeover.allCases.firstIndex(of: takeover) ?? 0)))
    try await pair.prepare(for: stage)
    let (lapsed, taker) = (pair[0], pair[1])
    let hold = takeover == .inFlight ? lapsed.model.holdNextCall() : nil
    if takeover != .inFlight { try lapsed.relaunch(.once(at: .afterCommit(step: 0))) }
    let first = try #require(try await stage.start(on: lapsed, calls: stage.calls()).handle)
    if let hold { try await lapsed.waitUntilReached(hold) } else { #expect(await first.result == .interrupted) }
    try await pair.deliver(from: 0, to: 1)
    try await Self.expectRefusedHere(taker, job: first.job, leader: first.attempt, on: lapsed.replica)

    await pair.advance(0, by: Self.lapse)
    await pair.advance(1, by: Self.lapse - 20)
    taker.model.queue(stage.calls(variant: 1))
    let second = try await taker.engine.runHere(job: first.job)
    #expect(await second.result == .settled(.succeeded))
    #expect(try await taker.snapshot(first.job).attempts.first { $0.id == second.attempt }?.start.byHand == true)

    let late: AttemptResult
    switch takeover {
    case .inFlight:
      try await pair.deliver(from: 1, to: 0)
      late = await first.result
      hold?.release()
    case .resumedAfterSync:
      try await pair.deliver(from: 1, to: 0)
      late = try await Self.resume(lapsed)
    case .resumedApart:
      late = try await Self.resume(lapsed)
    }
    #expect(late == .settled(takeover == .resumedApart ? .succeeded : .stoodDown))
    try await pair.expectConverged()

    let outputs = try await ChapterOutputs.read(pair[0], job: first.job)
    #expect(try await ChapterOutputs.read(pair[1], job: first.job) == outputs)
    for device in pair.devices {
      let winner = takeover == .resumedApart ? first.attempt : second.attempt
      #expect(try await device.status(first.job) == .succeeded(winner))
    }
    try Self.expectTakerKept(stage, outputs, job: first.job, lapsed: first.attempt, taker: second.attempt, lateWrites: takeover == .resumedApart)
  }

  private static func resume(_ device: ChapterDevice) async throws -> AttemptResult {
    let resumed = try await device.relaunch().resumeInterruptedAttempts()
    #expect(resumed.count == 1)
    return try await #require(resumed.first).result
  }

  /// The taker's first-writer-wins outputs stand; the lapsed attempt adds only what the table lets a duplicate add: one more version that becomes the head as
  /// the register's last writer, and appended reviews after the taker's.
  private static func expectTakerKept(
    _ stage: ChapterStage, _ outputs: ChapterOutputs, job: EntityRef, lapsed: AttemptID, taker: AttemptID, lateWrites: Bool
  ) throws {
    let writers = lateWrites ? [taker, lapsed] : [taker]
    switch stage {
    case .plan:
      let card = try #require(outputs.cards[PlanCards.id(of: job)])
      #expect(outputs.cards.count == 1 && String(describing: card.changeSet).contains("The Dark Stair"))
    case .generate:
      let passes = outputs.reviews.filter(\.generationPass)
      #expect(passes.map(\.attempt) == writers && outputs.revisions.count == writers.count)
      #expect(outputs.head == passes.last?.draftRevision && Set(passes.compactMap(\.draftRevision)) == Set(outputs.revisions))
    case .review:
      #expect(outputs.reviews.map(\.attempt) == writers && Set(outputs.reviews.map(\.draftRevision)) == [outputs.head])
    case .finalizeReview:
      #expect(outputs.reads.map(\.attempt) == writers)
      let canon = try #require(outputs.canon)
      #expect(canon.review?.id == outputs.reads.first?.id && String(describing: canon.review?.kept).contains("the lamp room"))
    case .canonRefresh:
      let report = try #require(outputs.reports.first)
      #expect(outputs.reports.count == 1 && report.attempt == taker && report.proposal == RefreshRecords.card(of: job))
      #expect(outputs.cards[RefreshRecords.card(of: job)].map { String(describing: $0.changeSet).contains("A keeper who found the torn logbook.") } == true)
    }
  }
}
