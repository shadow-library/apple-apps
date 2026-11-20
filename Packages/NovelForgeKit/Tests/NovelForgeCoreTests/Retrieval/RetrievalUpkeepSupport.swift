import Foundation
import Synchronization
import Testing

@testable import NovelForgeCore

/// A sleep that ends only when the test advances it, or throws once its task is cancelled; records every sleep ever asked for.
final class ManualSleep: Sendable {
  private struct State {
    var next = 0
    var requested: [Duration] = []
    var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
  }

  private let state = Mutex(State())

  var requested: Int { state.withLock(\.requested.count) }
  var durations: [Duration] { state.withLock(\.requested) }
  var waiting: Int { state.withLock(\.waiting.count) }

  var sleep: @Sendable (Duration) async throws -> Void {
    { [self] duration in try await wait(duration) }
  }

  func advance() {
    let waiting = state.withLock { state in
      defer { state.waiting = [:] }
      return Array(state.waiting.values)
    }
    for continuation in waiting { continuation.resume() }
  }

  private func wait(_ duration: Duration) async throws {
    let id = state.withLock { state in
      state.next += 1
      state.requested.append(duration)
      return state.next
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let cancelled = state.withLock { state in
          guard !Task.isCancelled else { return true }
          state.waiting[id] = continuation
          return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
      }
    } onCancel: {
      state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(throwing: CancellationError())
    }
  }
}

/// Work that records each call in order and how many ran at once, holds the calls `hold` names until the test opens them, and answers embeddings from
/// `embeddings` (complete by default).
final class RecordedUpkeepWork: Sendable {
  enum Call: Hashable, Sendable {
    case catchUp(UUID)
    case embed(UUID)
  }

  private struct State {
    var calls: [Call] = []
    var inFlight = 0
    var most = 0
    var held: [Call: Int] = [:]
    var next = 0
    var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    var failures: [Call: Int] = [:]
    var embeddings: [UUID: [RetrievalEmbedding]] = [:]
    var cancelled: [Call] = []
  }

  private let state = Mutex(State())

  var calls: [Call] { state.withLock(\.calls) }
  var mostAtOnce: Int { state.withLock(\.most) }
  var cancelled: [Call] { state.withLock(\.cancelled) }

  func count(_ call: Call) -> Int { calls.count { $0 == call } }

  /// The next `times` calls of `call` wait until `open()`, or until their task is cancelled, and then throw `cancelled` if it was.
  func hold(_ call: Call, times: Int = 1) {
    state.withLock { $0.held[call, default: 0] += times }
  }

  func open() {
    let waiting = state.withLock { state in
      defer { state.waiting = [:] }
      return Array(state.waiting.values)
    }
    for continuation in waiting { continuation.resume() }
  }

  func fail(_ call: Call, times: Int = 1) {
    state.withLock { $0.failures[call, default: 0] += times }
  }

  func embeddings(_ novel: UUID, _ outcomes: [RetrievalEmbedding]) {
    state.withLock { $0.embeddings[novel] = outcomes }
  }

  var work: RetrievalUpkeep.Work {
    RetrievalUpkeep.Work(
      catchUp: { @concurrent [self] novel throws(RetrievalError) in
        try await run(.catchUp(novel))
      },
      embed: { @concurrent [self] novel, _ throws(RetrievalError) in
        try await run(.embed(novel))
        return state.withLock { state in
          guard var outcomes = state.embeddings[novel], !outcomes.isEmpty else { return RetrievalEmbedding(model: "fake/a") }
          let outcome = outcomes.removeFirst()
          state.embeddings[novel] = outcomes
          return outcome
        }
      })
  }

  private func run(_ call: Call) async throws(RetrievalError) {
    let (held, failing) = state.withLock { state -> (Bool, Bool) in
      state.calls.append(call)
      state.inFlight += 1
      state.most = max(state.most, state.inFlight)
      let held = (state.held[call] ?? 0) > 0
      if held { state.held[call, default: 0] -= 1 }
      let failing = (state.failures[call] ?? 0) > 0
      if failing { state.failures[call, default: 0] -= 1 }
      return (held, failing)
    }
    defer { state.withLock { $0.inFlight -= 1 } }
    if held { await waitForOpen() }
    if Task.isCancelled {
      state.withLock { $0.cancelled.append(call) }
      throw .cancelled
    }
    if failing { throw .indexUnavailable([]) }
  }

  private func waitForOpen() async {
    let id = state.withLock { state in
      state.next += 1
      return state.next
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let cancelled = state.withLock { state in
          guard !Task.isCancelled else { return true }
          state.waiting[id] = continuation
          return false
        }
        if cancelled { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.waiting.removeValue(forKey: id) }?.resume()
    }
  }

  var holding: Int { state.withLock(\.waiting.count) }
}

/// The sets of novels an upkeep saw change, in order.
final class NoticedNovels: Sendable {
  private let sets = Mutex<[Set<UUID>]>([])

  var all: [Set<UUID>] { sets.withLock(\.self) }

  var hook: @Sendable (Set<UUID>) -> Void {
    { [self] novels in sets.withLock { $0.append(novels) } }
  }
}

enum UpkeepWait {
  /// Polls until `condition` holds; a condition that never does fails the test at the deadline.
  static func until(_ what: String, _ condition: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<6_000 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("never: \(what)")
  }
}
