import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// Two kills in a row: the second ends the process that was resuming the first.
struct DoubleKill: Sendable, CustomTestStringConvertible {
  let path: FinalizePath
  let kills: [ChainKill]

  var testDescription: String { kills.map(\.testDescription).joined(separator: ", then ") }

  static let cases = [
    DoubleKill(path: .commit, kills: [.runner(.plan, .call(step: 0)), .before(.planCard)]),
    DoubleKill(path: .commit, kills: [.runner(.plan, .afterCommit(step: 0)), .runner(.plan, .beforeCommit(step: 1))]),
    DoubleKill(path: .commit, kills: [.runner(.generate, .call(step: 1)), .runner(.generate, .call(step: 1))]),
    DoubleKill(path: .commit, kills: [.runner(.generate, .afterCommit(step: 2)), .runner(.generate, .beforeCommit(step: 4))]),
    DoubleKill(path: .commit, kills: [.pinned(.review), .pinned(.review)]),
    DoubleKill(path: .commit, kills: [.runner(.finalizeReview, .call(step: 0)), .runner(.finalizeReview, .committed(write: 0))]),
    DoubleKill(path: .commit, kills: [.routineKept, .runner(.refresh, .call(step: 0))]),
    DoubleKill(path: .commit, kills: [.runner(.refresh, .beforeCommit(step: 1)), .runner(.refresh, .beforeCommit(step: 1))]),
    DoubleKill(path: .card, kills: [.cardContent, .before(.refresh)]),
  ]
}

/// One chapter driven plan → plan card → generate → judge review → approve → finalize review → answers → finalize → canon refresh, as nf-eval drives it, over
/// a vault in a file and a scripted model. Each run is killed at one seam the uninterrupted chain reaches, found by recording every engine and runner crash
/// seam it passes (each runner write, each step's before and after commit, each call opening, each start's pins) and every point between its transactions;
/// a new process on the same file then launches as the app does (the pending-action sweep, then `resumeInterruptedAttempts`) and carries the chain on.
@Suite("Plan to canon killed and resumed", TestTimeLimit.standard)
struct ChapterInterruptionTests {
  static let steps: [ChainStage: Int] = [.plan: 2, .generate: 6, .review: 2, .finalizeReview: 3, .refresh: 2]

  @Test func shouldReachEveryCrashSeamOfEveryPipeline() async throws {
    let recording = try await ChainRecording.recording(.commit)
    #expect(recording.names == ["chapter-plan", "generation", "judge", "judge", "continuity", "text"])
    for (stage, count) in Self.steps {
      let seams = Set(recording.kills.filter { $0.stage == stage })
      let writes = (0...count).map { ChainKill.runner(stage, .committed(write: $0)) }
      let commits = (0..<count).flatMap { [ChainKill.runner(stage, .beforeCommit(step: $0)), .runner(stage, .afterCommit(step: $0))] }
      let calls = (0..<count).filter { seams.contains(.runner(stage, .call(step: $0))) }.map { ChainKill.runner(stage, .call(step: $0)) }
      #expect(seams == Set([.pinned(stage), .before(stage)] + writes + commits + calls), "\(stage.rawValue)")
      #expect(calls.map { recording.lost($0)?.count } == calls.map { _ in 1 }, "each call opening loses its one call")
    }
    #expect(recording.kills.count { if case .runner(_, .call) = $0 { true } else { false } } == recording.names.count)
  }

  @Test func shouldLeaveTheSameFootprintRunUninterrupted() async throws {
    let run = try await ChainRun.run([], path: .commit)
    defer { run.vault.remove() }
    try await run.expectCanon(losing: [], path: .commit)
  }

  @Test(arguments: try await ChainRecording.recording(.commit).kills)
  func shouldFinalizeTheChapterOnceWhenKilledAndResumed(_ kill: ChainKill) async throws {
    let run = try await ChainRun.run([kill], path: .commit)
    defer { run.vault.remove() }
    #expect(run.sweeps == [[]], "applying the plan card leaves no action for the launch sweep")
    try await run.expectCanon(losing: [kill], path: .commit)
  }

  @Test(arguments: try await ChainRecording.recording(.card).kills.filter { $0.stage == .finalize || $0 == .before(.refresh) })
  func shouldFinalizeThroughTheCardOnceWhenKilledAndResumed(_ kill: ChainKill) async throws {
    let run = try await ChainRun.run([kill], path: .card)
    defer { run.vault.remove() }
    let sweep = try #require(run.sweeps.first)
    if kill == .cardContent {
      #expect(sweep == [.resumed(proposal: ChainScript.finalizeCard, [ProposalActionResult(index: 0, outcome: .known(.applied), summary: "finalized chapter 1")])])
    } else {
      #expect(sweep.isEmpty)
    }
    try await run.expectCanon(losing: [kill], path: .card)
  }

  @Test(arguments: DoubleKill.cases)
  func shouldFinalizeTheChapterOnceWhenKilledAgainWhileResuming(_ double: DoubleKill) async throws {
    let run = try await ChainRun.run(double.kills, path: double.path)
    defer { run.vault.remove() }
    #expect(run.sweeps.count == 2)
    let finalized = run.sweeps.flatMap { $0 }.map { sweep -> Bool in
      guard case .resumed(ChainScript.finalizeCard, let results) = sweep else { return false }
      return results.map(\.outcome) == [.known(.applied)]
    }
    #expect(finalized == (double.kills.first == .cardContent ? [true] : []))
    try await run.expectCanon(losing: double.kills, path: double.path)
  }
}
