import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// Interrupts every step of every pipeline twice, as the system ending the phone's background time does, releasing the lease each time: first before the
/// step runs, then, once resumed, at the first text its call streams; the third time the step runs through. A step that sends no call is interrupted once.
final class EveryStepGate: Sendable {
  private struct State {
    var entries: [String: Int] = [:]
    var fired = 0
    var answers: [JobInterruption] = []
    var engine: JobEngine?
  }

  private let state = Mutex(State())

  var fired: Int { state.withLock { $0.fired } }

  var answers: [JobInterruption] { state.withLock { $0.answers } }

  func steps(of kind: NovelJobKind) -> Int {
    state.withLock { $0.entries.keys.count { $0.hasPrefix("\(kind.rawValue) ") } }
  }

  func attach(_ engine: JobEngine) {
    state.withLock { $0.engine = engine }
  }

  var catalog: @Sendable (NovelJobKind) -> NovelPipelineDefinition {
    { [self] kind in
      guard case .ready(let pipeline) = PipelineCatalog.definition(for: kind) else { return PipelineCatalog.definition(for: kind) }
      return .ready(
        NovelPipeline(
          version: pipeline.version, first: pipeline.first, steps: pipeline.steps.mapValues { InterruptedStep(gate: self, inner: $0) }, course: pipeline.course))
    }
  }

  func run(_ inner: any JobStep, _ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let key = "\(context.target.kind.rawValue) \(context.attempt.step.index)"
    let (entry, engine) = state.withLock { state in
      defer { state.entries[key, default: 0] += 1 }
      return (state.entries[key, default: 0], state.engine)
    }
    guard let engine, entry < 2 else { return try await inner.run(input, in: context) }
    guard entry == 1 else {
      interrupt(context, on: engine)
      try await Task.sleep(for: .seconds(3600))
      throw EngineFixtureError(description: "the step was not interrupted")
    }
    let (outer, attempt) = (ModelCallHooks.output, context.attempt)
    let cut = Mutex(false)
    let observer: ModelOutputObserver = { [self] event in
      outer?(event)
      guard case .delta = event,
        cut.withLock({ cut in
          defer { cut = true }
          return !cut
        })
      else { return }
      interrupt(context, on: engine)
      let deadline = ContinuousClock.now + .seconds(30)
      while !attempt.isStopping, ContinuousClock.now < deadline { usleep(1_000) }
    }
    return try await ModelCallHooks.$output.withValue(observer) { try await inner.run(input, in: context) }
  }

  private func interrupt(_ context: JobStepContext, on engine: JobEngine) {
    state.withLock { $0.fired += 1 }
    let job = context.attempt.job.ref
    Task {
      guard let answer = try? await engine.interrupt(job: job, releasingLease: true) else { return }
      state.withLock { $0.answers.append(answer) }
    }
  }
}

struct InterruptedStep: JobStep {
  let gate: EveryStepGate
  let inner: any JobStep

  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    try await gate.run(inner, state, in: context)
  }
}

/// The phone with no worker named runs every job of the chapter by hand, and each run is interrupted with its lease released before each step and in the
/// middle of each call; Resume continues the one attempt from its checkpoint until it succeeds.
@Suite("Hand-off: the phone alone, interrupted at every step", TestTimeLimit.standard)
struct HandOffPhoneTests {
  private static let steps: [ChapterStage: Int] = [.plan: 2, .generate: 6, .review: 2, .finalizeReview: 3, .canonRefresh: 2]

  @Test func shouldLeaveTheCanonOfAnUninterruptedRunSendingEachCutCallOnceMore() async throws {
    let world = try await HandOffWorld.make([.phone], seed: 0x4852)
    let phone = world[0]
    let gate = EveryStepGate()
    gate.attach(try phone.relaunch(catalog: gate.catalog))
    #expect(try await phone.engine.worker() == VaultWorker.none)

    let baseline = try await HandOffBaseline.recording.value
    for stage in ChapterStage.allCases {
      let job = try await stage.request(on: phone)
      let waiting: JobWaitingFor = stage.kind.queuesForWorker ? .worker(.none) : .requester(world.device(0, seenFrom: 0))
      guard case .queued(let queued)? = try await phone.placement(of: job) else { throw EngineFixtureError(description: "\(stage) is not queued") }
      #expect(queued.waitingFor == waiting, "\(stage)")
      #expect(try await phone.drain().isEmpty, "a phone with no worker named starts nothing by itself")

      let calls = stage.calls()
      phone.model.queue(calls.flatMap { [$0, $0] })
      let first = try await phone.engine.runHere(job: job)
      var (handle, interruptions) = (first, 0)
      while true {
        let result = await handle.result
        if result == .settled(.succeeded) { break }
        guard result == .interrupted, interruptions < 40 else { throw EngineFixtureError(description: "\(stage) ended \(result)") }
        interruptions += 1
        try await engineEventually("the interrupt of \(stage) returned") { gate.answers.count == gate.fired }
        try await Self.expectInterrupted(job, attempt: first.attempt, stage: stage, on: phone)
        handle = try await phone.engine.resumeHere(job: job)
        #expect(handle.attempt == first.attempt, "Resume continues the one attempt")
      }
      #expect(gate.steps(of: stage.kind) == Self.steps[stage], "\(stage) ran its steps")
      #expect(interruptions == (Self.steps[stage] ?? 0) + calls.count, "\(stage) was interrupted before each step and in each call")
      let attempts = try await phone.attempts(job)
      #expect(attempts.map(\.id) == [first.attempt] && attempts.first?.start.byHand == true)
      try await stage.complete(on: phone, job: job)
    }

    #expect(gate.answers.allSatisfy { if case .interrupted = $0 { true } else { false } })
    let expected = ChapterStage.allCases.flatMap { baseline.calls[$0] ?? [] }.flatMap { [$0, $0] }
    #expect(phone.model.scripted.requests.map(ChainScript.name) == expected, "each cut call is sent once more and no other")
    #expect(phone.model.scripted.remainingCalls == 0)
    try await world.expectSameWorkAsOneDevice(through: .canonRefresh, cutCalls: expected.count / 2)
  }

  /// Interrupted here with the lease released: the phone holds the run to resume, and a job of the worker's kinds reads queued in the vault's backlog.
  private static func expectInterrupted(_ job: EntityRef, attempt: AttemptID, stage: ChapterStage, on phone: ChapterDevice) async throws {
    guard case .interrupted(let interrupted)? = try await phone.placement(of: job) else {
      Issue.record("\(stage) does not read interrupted here: \(String(describing: try await phone.placement(of: job)))")
      return
    }
    let runs = try await phone.engine.interruptedRuns()
    #expect(interrupted.attempt == attempt && runs.map(\.attempt) == [attempt] && runs.first?.step == interrupted.step)
    let backlog = try await phone.backlog()
    #expect(backlog.worker == .none && !backlog.isWorkerHere)
    #expect(backlog.jobs.value?.map(\.job) == (stage.kind.queuesForWorker ? [job] : []))
  }
}
