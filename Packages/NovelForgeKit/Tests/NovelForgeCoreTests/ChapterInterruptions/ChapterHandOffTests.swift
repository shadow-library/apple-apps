import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// Where a hand-off interrupts the job: before the step runs, or once the step's first call has streamed text, so that call is cut and sent again.
enum HandOffPoint: String, Sendable {
  case beforeStep
  case midCall
}

/// The step a chain process is running, for the routes its calls take.
enum ChainSteps {
  @TaskLocal static var current: (kind: NovelJobKind, step: String)?
}

/// Records each step the chain runs and the task of each call, and can hold one step of one pipeline and have the engine interrupt the job there, as the
/// system ending the app's background time does; the progress of the interrupted run and of its resume is recorded from that step on.
final class HandOffGate: Sendable {
  private struct State {
    var fired = false
    var resumeObserved = false
    var answers: [JobInterruption] = []
    var engine: JobEngine?
    var steps: [NovelJobKind: [String]] = [:]
    var tasks: [NovelJobKind: [String: Set<ModelTask>]] = [:]
    var observers: [Task<[JobRunProgress], Never>] = []
  }

  let kind: NovelJobKind?
  let index: Int
  let point: HandOffPoint
  let releasingLease: Bool
  private let state = Mutex(State())

  init(kind: NovelJobKind? = nil, index: Int = 0, point: HandOffPoint = .beforeStep, releasingLease: Bool = false) {
    self.kind = kind
    self.index = index
    self.point = point
    self.releasingLease = releasingLease
  }

  var answers: [JobInterruption] { state.withLock { $0.answers } }

  var steps: [NovelJobKind: [String]] { state.withLock { $0.steps } }

  var tasks: [NovelJobKind: [String: Set<ModelTask>]] { state.withLock { $0.tasks } }

  /// What each recorded run reported, once every recorded run ended.
  var progress: [[JobRunProgress]] {
    get async {
      var logs: [[JobRunProgress]] = []
      for observer in state.withLock({ $0.observers }) { logs.append(await observer.value) }
      return logs
    }
  }

  func attach(_ engine: JobEngine) {
    state.withLock { $0.engine = engine }
  }

  var catalog: @Sendable (NovelJobKind) -> NovelPipelineDefinition {
    { [self] kind in
      guard case .ready(let pipeline) = PipelineCatalog.definition(for: kind) else { return PipelineCatalog.definition(for: kind) }
      return .ready(
        NovelPipeline(
          version: pipeline.version, first: pipeline.first, steps: pipeline.steps.mapValues { GatedStep(gate: self, inner: $0) }, course: pipeline.course))
    }
  }

  func routed(_ route: ModelRoute) {
    guard let current = ChainSteps.current else { return }
    _ = state.withLock { $0.tasks[current.kind, default: [:]][current.step, default: []].insert(route.task) }
  }

  func run(_ inner: any JobStep, _ input: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let (target, step) = (context.target.kind, context.attempt.step)
    let (firing, engine) = state.withLock { state -> (Bool, JobEngine?) in
      if !state.fired { state.steps[target, default: []].append(step.name) }
      guard target == kind, step.index == index else { return (false, nil) }
      if !state.fired {
        state.fired = true
        return (true, state.engine)
      }
      if !state.resumeObserved, let engine = state.engine {
        state.resumeObserved = true
        state.observers.append(Self.collect(engine.observeRun(attempt: context.attempt.attempt)))
      }
      return (false, nil)
    }
    let body = { () async throws -> AttemptStepOutput in try await ChainSteps.$current.withValue((target, step.name)) { try await inner.run(input, in: context) } }
    guard firing, let engine else { return try await body() }
    state.withLock { $0.observers.append(Self.collect(engine.observeRun(attempt: context.attempt.attempt))) }
    switch point {
    case .beforeStep:
      interrupt(context, on: engine)
      try await Task.sleep(for: .seconds(3600))
      throw EngineFixtureError(description: "the gated step was not interrupted")
    case .midCall:
      let outer = ModelCallHooks.output
      let cut = Mutex(false)
      let attempt = context.attempt
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
      return try await ModelCallHooks.$output.withValue(observer) { try await body() }
    }
  }

  private func interrupt(_ context: JobStepContext, on engine: JobEngine) {
    let (job, releasingLease) = (context.attempt.job.ref, releasingLease)
    Task {
      guard let answer = try? await engine.interrupt(job: job, releasingLease: releasingLease) else { return }
      state.withLock { $0.answers.append(answer) }
    }
  }

  private static func collect(_ stream: AsyncStream<JobRunProgress>) -> Task<[JobRunProgress], Never> {
    Task {
      var seen: [JobRunProgress] = []
      for await progress in stream { seen.append(progress) }
      return seen
    }
  }
}

struct GatedStep: JobStep {
  let gate: HandOffGate
  let inner: any JobStep

  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    try await gate.run(inner, state, in: context)
  }
}

struct HandOffBoundary: Sendable, CustomTestStringConvertible {
  let stage: ChainStage
  let kind: NovelJobKind
  let index: Int
  let point: HandOffPoint
  let releasingLease: Bool

  var testDescription: String { "\(stage.rawValue) \(point.rawValue) at step \(index)\(releasingLease ? ", lease released" : "")" }

  /// The kill that loses what this hand-off loses: nothing before a step, the step's calls mid-call.
  var lost: [ChainKill] { point == .midCall ? [.runner(stage, .call(step: index))] : [] }

  static let kinds: [ChainStage: NovelJobKind] = [.plan: .plan, .generate: .generate, .review: .review, .finalizeReview: .finalizeReview, .refresh: .canonRefresh]

  static var beforeSteps: [HandOffBoundary] {
    ChapterInterruptionTests.steps.sorted { $0.key.rawValue < $1.key.rawValue }.flatMap { stage, count in
      (0..<count).flatMap { index in
        [false, true].map { releasing in HandOffBoundary(stage: stage, kind: kinds[stage] ?? .plan, index: index, point: .beforeStep, releasingLease: releasing) }
      }
    }
  }

  /// Every step of the chain that sends a call.
  static var midCalls: [HandOffBoundary] {
    get async throws {
      try await ChainRecording.recording(.commit).kills.compactMap { kill in
        guard case .runner(let stage, .call(let index)) = kill, let kind = kinds[stage] else { return nil }
        return HandOffBoundary(stage: stage, kind: kind, index: index, point: .midCall, releasingLease: index % 2 == 0)
      }
    }
  }
}

/// The chapter driven plan to canon in one process, its job interrupted through `JobEngine.interrupt` before each step of each pipeline and resumed with
/// `resumeHere`: the run continues its one attempt from the checkpoint, sends no call twice and leaves the footprint of a run never interrupted.
@Suite("Plan to canon interrupted at each step and resumed here", TestTimeLimit.standard)
struct ChapterHandOffTests {
  @Test(arguments: HandOffBoundary.beforeSteps)
  func shouldFinalizeTheChapterOnceWhenInterruptedBeforeAStepAndResumedHere(_ boundary: HandOffBoundary) async throws {
    try await Self.expectHandedOff(boundary)
  }

  @Test(arguments: try await HandOffBoundary.midCalls)
  func shouldFinalizeTheChapterOnceSendingTheCutCallAgainWhenInterruptedMidCall(_ boundary: HandOffBoundary) async throws {
    try await Self.expectHandedOff(boundary)
  }

  @Test func shouldRunEachPipelinesCourseInOrderWithTheTasksItCharts() async throws {
    let vault = try await ChainVault.make(calls: ChainScript.calls)
    defer { vault.remove() }
    let gate = HandOffGate()
    let process = try vault.open(catalog: gate.catalog, routed: gate.routed)
    #expect(try await process.drive(.commit))
    let (steps, tasks) = (gate.steps, gate.tasks)
    for kind in NovelJobKind.allCases {
      guard case .ready(let pipeline) = PipelineCatalog.definition(for: kind), let course = pipeline.course else {
        Issue.record("\(kind.rawValue) charts no course")
        continue
      }
      #expect(steps[kind] == course.order, "\(kind.rawValue) runs its course in order")
      let charted = course.tasks.filter { course.order.contains($0.key) }.mapValues { Set([$0]) }
      #expect(tasks[kind] ?? [:] == charted, "\(kind.rawValue) calls the tasks its course charts")
    }
  }

  private static func expectHandedOff(_ boundary: HandOffBoundary, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let recording = try await ChainRecording.recording(.commit)
    let vault = try await ChainVault.make(calls: recording.calls(losing: boundary.lost).map { ChainScript.calls[$0] })
    defer { vault.remove() }
    let gate = HandOffGate(kind: boundary.kind, index: boundary.index, point: boundary.point, releasingLease: boundary.releasingLease)
    let process = try vault.open(catalog: gate.catalog, resumesHere: true)
    gate.attach(process.engine)
    #expect(try await process.drive(.commit), sourceLocation: sourceLocation)
    let answers = gate.answers
    #expect(answers.count == 1, sourceLocation: sourceLocation)
    guard case .interrupted(let attempt)? = answers.first else {
      Issue.record("the interrupt answered \(answers)", sourceLocation: sourceLocation)
      return
    }
    let job = try #require(try await process.job(boundary.kind), sourceLocation: sourceLocation)
    #expect(try await process.snapshot(job).attempts.map(\.id) == [attempt], sourceLocation: sourceLocation)
    #expect(try await process.engine.interruptedRuns().isEmpty, sourceLocation: sourceLocation)
    try await ChainRun(vault: vault, last: process, sweeps: []).expectCanon(losing: boundary.lost, path: .commit, sourceLocation: sourceLocation)
    let runs = await gate.progress
    #expect(runs.count == 2 && runs.allSatisfy { !$0.isEmpty }, "the interrupted run and its resume report progress", sourceLocation: sourceLocation)
    for run in runs {
      let monotone = zip(run, run.dropFirst()).allSatisfy { $0.tokensReceived <= $1.tokensReceived && $0.stepsTotal <= $1.stepsTotal && $0.stepsDone <= $1.stepsDone }
      #expect(monotone, "progress only grows: \(run.map { "\($0.stepsDone)/\($0.stepsTotal) \($0.tokensReceived)/\($0.tokensExpected)" })", sourceLocation: sourceLocation)
    }
  }
}
