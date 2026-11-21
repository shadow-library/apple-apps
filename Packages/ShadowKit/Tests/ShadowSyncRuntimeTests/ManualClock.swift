import Synchronization

/// Time moves only through `advance(by:)`; sleepers wake once their deadline has passed. With `wakesCancelledSleepers` a cancelled sleeper
/// still wakes at its deadline, as a timer does that woke just before it was cancelled.
final class ManualClock: Clock {
  struct Instant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }

    func duration(to other: Instant) -> Duration { other.offset - offset }

    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var sleepers: [Int: Sleeper] = [:]
    var nextID = 0
  }

  private let state = Mutex(State())
  private let wakesCancelledSleepers: Bool

  init(wakesCancelledSleepers: Bool = false) {
    self.wakesCancelledSleepers = wakesCancelledSleepers
  }

  var now: Instant { state.withLock { $0.now } }

  var minimumResolution: Duration { .zero }

  var sleeperCount: Int { state.withLock { $0.sleepers.count } }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let outcome: Result<Void, any Error>? = state.withLock { state in
          if Task.isCancelled, !wakesCancelledSleepers { return .failure(CancellationError()) }
          if deadline <= state.now { return .success(()) }
          state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
          return nil
        }
        if let outcome { continuation.resume(with: outcome) }
      }
    } onCancel: {
      guard !wakesCancelledSleepers else { return }
      state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let due = state.withLock { state in
      state.now = state.now.advanced(by: duration)
      let now = state.now
      let due = state.sleepers.filter { $0.value.deadline <= now }
      for id in due.keys { state.sleepers.removeValue(forKey: id) }
      return due.values.map(\.continuation)
    }
    for continuation in due { continuation.resume() }
  }
}
