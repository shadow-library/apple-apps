import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import ShadowJobs

/// A model call stand-in: a frozen call never answers, as a request in flight when the process ends, and ends only when its task is cancelled.
final class FakeModel: Sendable {
  private struct State {
    var calls = 0
    var frozen = 0
  }

  private let freezing: Set<Int>
  private let state = Mutex(State())

  init(freezing: Set<Int> = []) {
    self.freezing = freezing
  }

  var calls: Int { state.withLock { $0.calls } }
  var frozen: Int { state.withLock { $0.frozen } }

  func reply() async throws {
    try Task.checkCancellation()
    let number = state.withLock { state in
      defer { state.calls += 1 }
      return state.calls
    }
    guard freezing.contains(number) else { return }
    state.withLock { $0.frozen += 1 }
    defer { state.withLock { $0.frozen -= 1 } }
    try await Task.sleep(for: .seconds(3600))
  }

  func waitFrozen() async throws {
    try await eventually("a call is in flight") { self.frozen > 0 }
  }
}

/// Each step opens a call (its id joins the attempt in the call's own transaction, as the ledger's would), waits for the model, and appends its output
/// under the job and step, so a second write of one step's output is refused by the store.
struct FakeStep: PipelineStep {
  let name: String
  let next: String?
  let store: VaultStore
  let model: FakeModel

  func run(_ input: JSONValue, in context: AttemptStepContext) async throws -> AttemptStepOutput {
    guard let text = input["text"]?.stringValue else { throw FixtureError(description: "the checkpoint holds no text") }
    let call = UUID.v7()
    try await store.write { transaction in try context.recordCall(call, in: &transaction) }
    try await model.reply()
    let output = "\(text)>\(name)"
    let ref = FakeStep.output(job: context.job.ref, step: name)
    let item: [String: JSONValue] = ["step": .string(name), "text": .string(output)]
    return AttemptStepOutput(state: ["text": .string(output)], next: next) { transaction in _ = try transaction.append(ref, item: item) }
  }

  static func output(job: EntityRef, step: String) -> EntityRef {
    EntityRef(kind: JobFixture.outputKind, key: .natural(scope: "com.shadow.library.shadowjobs.test", kind: JobFixture.outputKind, components: [job.key.rawValue, step]))
  }
}

/// A heartbeat that sleeps until the test ticks it.
final class Ticker: Sendable {
  private struct State {
    var waiter: CheckedContinuation<Void, any Error>?
    var pending = 0
  }

  private let state = Mutex(State())

  func sleep() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let resume = state.withLock { state -> Bool in
          if Task.isCancelled { return true }
          guard state.pending == 0 else {
            state.pending -= 1
            return true
          }
          state.waiter = continuation
          return false
        }
        if resume { Task.isCancelled ? continuation.resume(throwing: CancellationError()) : continuation.resume() }
      }
    } onCancel: {
      state.withLock { state in
        defer { state.waiter = nil }
        return state.waiter
      }?.resume(throwing: CancellationError())
    }
  }

  func tick() {
    let waiter = state.withLock { state in
      guard let waiter = state.waiter else {
        state.pending += 1
        return CheckedContinuation<Void, any Error>?.none
      }
      state.waiter = nil
      return waiter
    }
    waiter?.resume()
  }
}

struct JobWorld {
  static let expected = ["draft": "seed>draft", "expand": "seed>draft>expand", "title": "seed>draft>expand>title"]

  let clock = DeviceClock()
  let store: VaultStore
  let key: JobKey

  init() async throws {
    store = try JobFixture.open(clock: clock)
    key = try JobFixture.key()
    let request = JobFixture.request(key, replica: store.replica)
    _ = try await store.write { transaction in try JobRecords.request(request, in: &transaction) }
  }

  func pipeline(_ model: FakeModel, in store: VaultStore? = nil) -> AttemptPipeline {
    let store = store ?? self.store
    return AttemptPipeline(
      first: "draft",
      steps: [
        "draft": FakeStep(name: "draft", next: "expand", store: store, model: model), "expand": FakeStep(name: "expand", next: "title", store: store, model: model),
        "title": FakeStep(name: "title", next: nil, store: store, model: model),
      ])
  }

  func runner(_ faults: AttemptRunner.Faults = .none, ticker: Ticker? = nil, store: VaultStore? = nil, clock: DeviceClock? = nil) -> AttemptRunner {
    let timing = AttemptRunner.Timing(heartbeat: LeaseTerms.heartbeat) { _ in
      guard let ticker else { return try await Task.sleep(for: .seconds(3600)) }
      try await ticker.sleep()
    }
    return AttemptRunner(store: store ?? self.store, clock: LeaseClock(trusted: nil, device: (clock ?? self.clock).function), timing: timing, faults: faults)
  }

  func start(_ runner: AttemptRunner, _ model: FakeModel, byHand: Bool = false) async throws -> AttemptHandle {
    try await runner.start(job: key.ref, pipeline: pipeline(model), input: ["text": "seed"], pinned: ["plan": "p1"], byHand: byHand)
  }

  func status() async throws -> JobStatus {
    JobStatus(try await JobFixture.snapshot(key.ref, in: store), at: LeaseInstant(date: clock.now, source: .device))
  }

  /// Every output written once, each in exactly one change.
  func expectOutputsWrittenOnce(_ steps: Set<String> = Set(Self.expected.keys)) async throws {
    let writes = try await JobFixture.outputWrites(in: store)
    #expect(writes == Dictionary(uniqueKeysWithValues: steps.map { (FakeStep.output(job: key.ref, step: $0), 1) }))
    #expect(try await JobFixture.outputs(in: store) == Self.expected.filter { steps.contains($0.key) })
  }
}

extension AttemptRunner.Faults {
  /// Crashes the first time the run reaches `point`.
  static func once(at point: Point) -> Self {
    let fired = Mutex(false)
    return Self { reached in
      guard reached == point else { return false }
      return fired.withLock { fired in
        defer { fired = true }
        return !fired
      }
    }
  }
}
