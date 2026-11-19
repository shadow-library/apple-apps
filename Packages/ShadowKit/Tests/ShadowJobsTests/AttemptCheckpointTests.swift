import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import ShadowJobs

@Suite("Attempt checkpoint compare-and-set", TestTimeLimit.quick)
struct AttemptCheckpointTests {
  @Test func shouldLetOnlyTheFirstOfTwoProcessesDrivingOneAttemptCommitAStep() async throws {
    let world = try await JobWorld()
    let gate = Gate()
    var steps = world.pipeline(FakeModel()).steps
    steps["expand"] = GatedStep(inner: FakeStep(name: "expand", next: "title", store: world.store, model: FakeModel()), gate: gate)
    let first = try await world.runner().start(
      job: world.key.ref, pipeline: AttemptPipeline(first: "draft", steps: steps), input: ["text": "seed"], pinned: ["plan": "p1"])
    try await eventually("the first process waits inside its expand step") { gate.isWaiting }

    let second = try #require(try await world.runner().resume(first.attempt) { _ in world.pipeline(FakeModel()) })
    #expect(await second.result == .settled(.succeeded))
    gate.open()

    #expect(await first.result == .interrupted)
    try await world.expectOutputsWrittenOnce()
    #expect(try await JobFixture.attempt(first.attempt, in: world.store).outcome == .succeeded)
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
  }

  @Test func shouldRefuseTheFirstProcessesStepOnceTheSecondCommittedJustThatStep() async throws {
    let world = try await JobWorld()
    let (firstGate, secondGate) = (Gate(), Gate())
    var firstSteps = world.pipeline(FakeModel()).steps
    firstSteps["expand"] = GatedStep(inner: FakeStep(name: "expand", next: "title", store: world.store, model: FakeModel()), gate: firstGate)
    let first = try await world.runner().start(
      job: world.key.ref, pipeline: AttemptPipeline(first: "draft", steps: firstSteps), input: ["text": "seed"], pinned: ["plan": "p1"])
    try await eventually("the first process waits inside its expand step") { firstGate.isWaiting }

    var secondSteps = world.pipeline(FakeModel()).steps
    secondSteps["title"] = GatedStep(inner: FakeStep(name: "title", next: nil, store: world.store, model: FakeModel()), gate: secondGate)
    let secondPipeline = AttemptPipeline(first: "draft", steps: secondSteps)
    let second = try #require(try await world.runner().resume(first.attempt) { _ in secondPipeline })
    try await eventually("the second process committed expand and waits inside title") { secondGate.isWaiting }
    #expect(try await JobFixture.attempt(first.attempt, in: world.store).step == AttemptStep(name: "title", index: 2))

    firstGate.open()
    #expect(await first.result == .interrupted)
    try await world.expectOutputsWrittenOnce(["draft", "expand"])
    secondGate.open()
    #expect(await second.result == .settled(.succeeded))
    try await world.expectOutputsWrittenOnce()
  }

  @Test func shouldHoldOnlyTheCheckpointStoredForTheAttempt() async throws {
    let store = try JobFixture.open()
    let id = try JobFixture.attemptID(0)
    let run = LocalRun(attempt: id, job: try JobFixture.key().ref, replica: store.replica, startedAt: Date(), stop: nil)
    let checkpoint = LocalCheckpoint(attempt: id, index: 1, next: "expand", state: ["text": "seed"])
    let held = try await store.write { transaction in
      let before = try JobsLocal.holds(checkpoint, in: transaction.database)
      try JobsLocal.begin(run, checkpoint: checkpoint, at: Date(), in: transaction.database)
      let moved = LocalCheckpoint(attempt: id, index: 2, next: "expand", state: ["text": "seed"])
      let renamed = LocalCheckpoint(attempt: id, index: 1, next: "title", state: ["text": "seed"])
      return [
        before, try JobsLocal.holds(checkpoint, in: transaction.database), try JobsLocal.holds(moved, in: transaction.database),
        try JobsLocal.holds(renamed, in: transaction.database),
      ]
    }
    #expect(held == [false, true, false, false])
  }
}

private final class Gate: Sendable {
  private struct State {
    var waiter: CheckedContinuation<Void, Never>?
    var isOpen = false
  }

  private let state = Mutex(State())

  var isWaiting: Bool { state.withLock { $0.waiter != nil } }

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resume = state.withLock { state -> Bool in
        guard !state.isOpen else { return true }
        state.waiter = continuation
        return false
      }
      if resume { continuation.resume() }
    }
  }

  func open() {
    let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.isOpen = true
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume()
  }
}

private struct GatedStep: PipelineStep {
  let inner: FakeStep
  let gate: Gate

  func run(_ input: JSONValue, in context: AttemptStepContext) async throws -> AttemptStepOutput {
    let output = try await inner.run(input, in: context)
    await gate.wait()
    return output
  }
}
