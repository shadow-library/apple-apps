import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Chapter replicas: both ask while connected", TestTimeLimit.standard)
struct ChapterReplicaConnectedTests {
  /// What the second device's own ask answers while the first device's attempt runs: the same job, or for a generate the refusal of a second one
  /// (generation.service.ts:242-243, as `GenerationRequests.generating` reads the job activity).
  private static func expectSecondAsk(_ start: StageStart, stage: ChapterStage, job: EntityRef) {
    switch (stage, start) {
    case (.generate, .refused(let code)): #expect(code == GenerationRequestError.generationRunning.code)
    case (.generate, _): Issue.record("a second generate was not refused: \(start)")
    case (_, .elsewhere(let answered)): #expect(answered == job)
    case (_, .running), (_, .refused): Issue.record("\(stage) on the second replica answered \(start)")
    }
  }

  @Test(arguments: ChapterStage.allCases)
  func shouldRunTheJobOnceAndShowItRunningOnTheOtherDevice(stage: ChapterStage) async throws {
    let pair = try await ChapterReplicas.make(seed: 0x34A0 + UInt64(stage.ordinal))
    try await pair.prepare(for: stage)
    let (here, there) = (pair[0], pair[1])
    let hold = here.model.holdNextCall()
    let handle = try #require(try await stage.start(on: here, calls: stage.calls()).handle)
    try await here.waitUntilReached(hold)
    try await pair.deliver(from: 0, to: 1)

    Self.expectSecondAsk(try await stage.start(on: there, calls: stage.calls(variant: 1)), stage: stage, job: handle.job)
    for byHand in [true, false] {
      do {
        _ = try await (byHand ? there.engine.runHere(job: handle.job) : there.engine.run(job: handle.job))
        Issue.record("\(stage) started beside the other device's live attempt, by hand: \(byHand)")
      } catch {
        guard case JobEngineError.runningElsewhere(let attempt, let replica) = error else { throw error }
        #expect(attempt == handle.attempt && replica == here.replica)
      }
    }
    let seen = try await there.progress(handle.job)
    #expect(seen.status == .running(handle.attempt) && seen.attempt == handle.attempt && seen.replica == here.replica && !seen.runningHere)
    #expect(there.model.requests == 0)

    hold.release()
    #expect(await handle.result == .settled(.succeeded))
    try await pair.expectConverged()
    for device in pair.devices {
      let attempts = try await device.snapshot(handle.job).attempts
      #expect(attempts.map(\.id) == [handle.attempt] && attempts.first?.outcome == .succeeded)
      #expect(try await device.status(handle.job) == .succeeded(handle.attempt))
      #expect(try await ChapterOutputs.read(device, job: handle.job).written(of: stage, job: handle.job) == (stage == .canonRefresh ? 2 : 1))
    }
  }

  /// Both devices start the job before either hears of the other's attempt: once they do, the later start stands down, its call aborted, and only the
  /// earlier one's outputs are written (plan, Leases, stopping and resuming).
  @Test(arguments: ChapterStage.allCases)
  func shouldStandTheLaterAttemptDownWhenBothDevicesStartTogether(stage: ChapterStage) async throws {
    let pair = try await ChapterReplicas.make(seed: 0x34A8 + UInt64(stage.ordinal))
    try await pair.prepare(for: stage)
    let holds = [pair[0].model.holdNextCall(), pair[1].model.holdNextCall()]
    var handles = [JobRunHandle]()
    for device in pair.devices {
      let calls = stage.calls(variant: device.index)
      handles.append(try #require(try await stage.start(on: device, calls: calls).handle, "\(stage) did not run on replica \(device.index)"))
      try await device.waitUntilReached(holds[device.index])
    }
    #expect(handles[0].job == handles[1].job)
    try await pair.deliver(from: 0, to: 1)
    try await pair.deliver(from: 1, to: 0)
    #expect(await handles[1].result == .settled(.stoodDown))
    holds[0].release()
    #expect(await handles[0].result == .settled(.succeeded))
    try await pair.expectConverged()

    let outputs = try await ChapterOutputs.read(pair[0], job: handles[0].job)
    #expect(try await ChapterOutputs.read(pair[1], job: handles[0].job) == outputs)
    #expect(outputs.written(of: stage, job: handles[0].job) == (stage == .canonRefresh ? 2 : 1))
    #expect((outputs.reviews.map(\.attempt) + outputs.reads.map(\.attempt) + outputs.reports.map(\.attempt)).allSatisfy { $0 == handles[0].attempt })
    for device in pair.devices { #expect(try await device.status(handles[0].job) == .succeeded(handles[0].attempt)) }
  }
}
