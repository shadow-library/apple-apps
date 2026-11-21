import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import Synchronization

/// A run on this device as its own process sees it: the step it is on, steps done of the steps it expects, and output tokens received of those expected.
/// `stepsTotal` and `tokensReceived` only grow; `tokensExpected` counts each finished call at what it produced, each live one at its output cap and each step
/// still ahead at its route's cap, so it shrinks as calls finish short of their cap and grows when a repair or a retry opens another call.
public struct JobRunProgress: Sendable, Equatable {
  public let attempt: AttemptID
  public let step: AttemptStep?
  public let stepsDone: Int
  public let stepsTotal: Int
  public let tokensReceived: Int
  public let tokensExpected: Int

  public init(attempt: AttemptID, step: AttemptStep?, stepsDone: Int, stepsTotal: Int, tokensReceived: Int, tokensExpected: Int) {
    self.attempt = attempt
    self.step = step
    self.stepsDone = stepsDone
    self.stepsTotal = stepsTotal
    self.tokensReceived = tokensReceived
    self.tokensExpected = tokensExpected
  }
}

/// The steps a pipeline usually runs, in order, with the model task of each step that calls one; a step off the course goes on at the step `rejoins` names.
/// Read for progress only, never to decide what runs.
struct PipelineCourse: Sendable {
  let order: [String]
  let tasks: [String: ModelTask]
  let rejoins: [String: String]

  init(_ order: [String], tasks: [String: ModelTask], rejoins: [String: String] = [:]) {
    self.order = order
    self.tasks = tasks
    self.rejoins = rejoins
  }

  func ahead(of step: String) -> [String] {
    if let index = order.firstIndex(of: step) { return Array(order[(index + 1)...]) }
    guard let rejoin = rejoins[step], let index = order.firstIndex(of: rejoin) else { return [] }
    return Array(order[index...])
  }
}

/// What a step expects when it begins: the steps after it and the output caps of its own calls and of the steps after it.
struct StepOutlook: Sendable, Equatable {
  let stepsAhead: Int
  let ownTokens: Int
  let aheadTokens: Int

  static let unknown = StepOutlook(stepsAhead: 0, ownTokens: 0, aheadTokens: 0)
}

/// The progress of every run tracked on this device, fed by `EngineStep` and the output hook of its calls; a run's observers finish when its handle ends.
final class RunProgressBoard: Sendable {
  private struct Tally {
    var step: AttemptStep?
    var stepsTotal = 0
    var outlook = StepOutlook.unknown
    var stepCalled = false
    var finished = 0
    var live: [UUID: (cap: Int, tokens: Int)] = [:]
    var received = 0

    func progress(of attempt: AttemptID) -> JobRunProgress {
      let expected = finished + live.values.reduce(0) { $0 + max($1.cap, $1.tokens) } + (stepCalled ? 0 : outlook.ownTokens) + outlook.aheadTokens
      return JobRunProgress(
        attempt: attempt, step: step, stepsDone: step?.index ?? 0, stepsTotal: stepsTotal, tokensReceived: received, tokensExpected: max(expected, received))
    }

    mutating func record(_ event: ModelOutputEvent) {
      switch event {
      case .started(let call, let cap):
        stepCalled = true
        let earlier = live[call]?.tokens ?? 0
        finished += earlier
        live[call] = (cap, 0)
      case .delta(let call, let tokens):
        live[call]?.tokens += tokens
      case .finished(let call, let tokens, _):
        guard live.removeValue(forKey: call) != nil else { return }
        finished += tokens
      }
      received = max(received, finished + live.values.reduce(0) { $0 + $1.tokens })
    }
  }

  private struct Run {
    var token: UUID?
    var tally = Tally()
    var observers: [UUID: AsyncStream<JobRunProgress>.Continuation] = [:]
  }

  private let runs = Mutex<[AttemptID: Run]>([:])
  /// Held while a value is handed to observers, so they see the values in the order they were made; never taken by an observer's `onTermination`.
  private let delivery = Mutex(())

  /// A run's steps may begin before its handle is tracked; a run tracked again after its attempt was resumed here keeps the tally, whose last step is the one
  /// the resume continues from, and finishes the observers of the run before it.
  func begin(_ attempt: AttemptID) -> UUID {
    let token = UUID()
    delivery.withLock { _ in
      let ended = runs.withLock { runs -> [AsyncStream<JobRunProgress>.Continuation] in
        var run = runs[attempt] ?? Run()
        let ended = run.token == nil ? [] : Array(run.observers.values)
        if run.token != nil { run.observers = [:] }
        run.token = token
        runs[attempt] = run
        return ended
      }
      for observer in ended { observer.finish() }
    }
    return token
  }

  func end(_ attempt: AttemptID, token: UUID) {
    delivery.withLock { _ in
      let ended = runs.withLock { runs -> [AsyncStream<JobRunProgress>.Continuation] in
        guard let run = runs[attempt], run.token == token else { return [] }
        runs[attempt] = nil
        return Array(run.observers.values)
      }
      for observer in ended { observer.finish() }
    }
  }

  func enter(_ attempt: AttemptID, step: AttemptStep, outlook: StepOutlook) {
    update(attempt) { tally in
      tally.step = step
      tally.outlook = outlook
      tally.stepCalled = false
      tally.stepsTotal = max(tally.stepsTotal, step.index + 1 + outlook.stepsAhead)
    }
  }

  func observer(for attempt: AttemptID) -> ModelOutputObserver {
    { [self] event in update(attempt) { $0.record(event) } }
  }

  /// Finishes at once for an attempt no run of which is tracked here.
  func observe(_ attempt: AttemptID) -> AsyncStream<JobRunProgress> {
    let (stream, continuation) = AsyncStream<JobRunProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    continuation.onTermination = { [weak self] _ in
      _ = self?.runs.withLock { $0[attempt]?.observers.removeValue(forKey: id) }
    }
    delivery.withLock { _ in
      let current = runs.withLock { runs -> JobRunProgress? in
        guard runs[attempt] != nil else { return nil }
        runs[attempt]?.observers[id] = continuation
        return runs[attempt]?.tally.progress(of: attempt)
      }
      guard let current else { return continuation.finish() }
      continuation.yield(current)
    }
    return stream
  }

  private func update(_ attempt: AttemptID, _ change: (inout Tally) -> Void) {
    delivery.withLock { _ in
      let (progress, observers) = runs.withLock { runs -> (JobRunProgress, [AsyncStream<JobRunProgress>.Continuation]) in
        var run = runs[attempt] ?? Run()
        let before = run.tally.progress(of: attempt)
        change(&run.tally)
        runs[attempt] = run
        let after = run.tally.progress(of: attempt)
        return (after, after == before ? [] : Array(run.observers.values))
      }
      for observer in observers { observer.yield(progress) }
    }
  }
}

extension JobServices {
  /// Each output cap read from the route the step's task takes at the steady pace in the standard mode, which the bundled catalog caps alike at every pace.
  func outlook(of step: String, in course: PipelineCourse?) async -> StepOutlook {
    guard let course else { return .unknown }
    let ahead = course.ahead(of: step)
    let router = await router { _ in nil }
    let cap = { (name: String) -> Int in course.tasks[name].flatMap { try? router.route(task: $0, pace: .steady).maxOutputTokens } ?? 0 }
    return StepOutlook(stepsAhead: ahead.count, ownTokens: cap(step), aheadTokens: ahead.reduce(0) { $0 + cap($1) })
  }
}
