import Synchronization

final class ManualClock: Clock {
  struct Instant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }

    func duration(to other: Instant) -> Duration { other.offset - offset }

    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  enum Mode {
    case advancesOnSleep
    case manual
  }

  private struct Sleeper {
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct Watcher {
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var sleepers: [Int: Sleeper] = [:]
    var watchers: [Watcher] = []
    var requestedSleeps: [Duration] = []
    var nextID = 0
  }

  private let mode: Mode
  private let state = Mutex(State())

  init(_ mode: Mode) {
    self.mode = mode
  }

  var now: Instant { state.withLock { $0.now } }

  var minimumResolution: Duration { .zero }

  var requestedSleeps: [Duration] { state.withLock { $0.requestedSleeps } }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = state.withLock { state in
      state.nextID += 1
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let outcome: Result<Void, any Error>? = state.withLock { state in
          state.requestedSleeps.append(state.now.duration(to: deadline))
          if Task.isCancelled { return .failure(CancellationError()) }
          if mode == .advancesOnSleep, state.now < deadline { state.now = deadline }
          if deadline <= state.now { return .success(()) }
          state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
          let ready = state.watchers.filter { $0.count <= state.sleepers.count }
          state.watchers.removeAll { $0.count <= state.sleepers.count }
          for watcher in ready { watcher.continuation.resume() }
          return nil
        }
        if let outcome { continuation.resume(with: outcome) }
      }
    } onCancel: {
      state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
    }
  }

  func waitForSleepers(_ count: Int = 1) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = state.withLock { state in
        guard state.sleepers.count < count else { return true }
        state.watchers.append(Watcher(count: count, continuation: continuation))
        return false
      }
      if ready { continuation.resume() }
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
