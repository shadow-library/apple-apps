import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// A generate job killed at every runner write, inside each call's opening transaction and around each commit; a relaunched engine resumes it to the outcome
/// of an uninterrupted run: one saved revision per save step, one recorded pass, and a paid call repeated only when its output was never checkpointed.
@Suite("Generation crashes", TestTimeLimit.property)
struct GenerationCrashTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let point: AttemptRunner.Faults.Point
    let calls: Int

    /// The step whose call ran and whose output the crash lost, so its reply is asked again.
    var repeated: Int? {
      switch point {
      case .call(let step), .beforeCommit(let step): step
      default: nil
      }
    }

    var testDescription: String { "\(point)" }
  }

  /// pin, draft, save, checks, judge, finish.
  static let steps = 6
  static let callSteps: Set<Int> = [1, 4]

  static let cases: [Case] =
    (0...steps).map { Case(point: .committed(write: $0), calls: 2) } + callSteps.sorted().map { Case(point: .call(step: $0), calls: 3) }
    + (0..<steps).flatMap { step in
      [Case(point: .beforeCommit(step: step), calls: callSteps.contains(step) ? 3 : 2), Case(point: .afterCommit(step: step), calls: 2)]
    }

  /// pin, draft, save, checks, judge, repair, save, checks, judge, finish: the repair call and the second save.
  static let repairCases: [Case] = [
    Case(point: .call(step: 5), calls: 5), Case(point: .beforeCommit(step: 5), calls: 5), Case(point: .afterCommit(step: 5), calls: 4),
    Case(point: .beforeCommit(step: 6), calls: 4), Case(point: .afterCommit(step: 6), calls: 4),
  ]

  @Test(arguments: cases)
  func shouldResumeAKilledGenerationToOneRevisionAndOnePass(_ crash: Case) async throws {
    var replies = [GenerationWorld.draftReply(), GenerationWorld.judgeReply()]
    if crash.repeated == 1 { replies.insert(GenerationWorld.draftReply(), at: 0) }
    if crash.repeated == 4 { replies.append(GenerationWorld.judgeReply()) }
    let world = try await GenerationWorld(calls: replies)
    try await Self.run(world, crash, saves: 1)
  }

  @Test(arguments: repairCases)
  func shouldResumeAKilledRepairToOneRevisionPerSave(_ crash: Case) async throws {
    let fixes = crash.repeated == 5 ? [GenerationWorld.patchReply(), GenerationWorld.patchReply()] : [GenerationWorld.patchReply()]
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.contradiction] + fixes + [GenerationWorld.judgeReply()])
    try await Self.run(world, crash, saves: 2)
  }

  private static func run(_ world: GenerationWorld, _ crash: Case, saves: Int) async throws {
    let engine = try world.engine(.once(at: crash.point))
    guard case .running(let handle) = try await engine.regenerateChapter(novel: world.novel, chapter: 1) else { throw EngineFixtureError(description: "not run here") }
    #expect(await handle.result == .interrupted)
    engine.relinquish()

    world.base.clock.advance(5)
    let relaunched = try world.engine()
    for resumed in try await relaunched.resumeInterruptedAttempts() { #expect(await resumed.result == .settled(.succeeded)) }

    let saved = try await world.saved(handle.job)
    #expect(saved.count == saves)
    let passes = try await world.passes()
    #expect(passes.count == 1 && passes.first?.draftRevision == saved.last?.id)
    #expect(try await world.history().head == saved.last?.id)
    let attempt = try await world.base.attempt(handle.attempt)
    #expect(attempt.outcome == .succeeded)
    let ledger = try await world.base.ledgerIDs()
    #expect(attempt.calls.count == crash.calls && Set(attempt.calls) == Set(ledger))
    #expect(world.base.packs.builds == 1)
    #expect(try await world.store.writerSnapshots(novel: world.novel, chapter: 1).count == saves)
    #expect(try await world.base.status(handle.job) == .succeeded(handle.attempt))
    #expect(try await world.lifecycle().review == .needsReview)
  }
}
