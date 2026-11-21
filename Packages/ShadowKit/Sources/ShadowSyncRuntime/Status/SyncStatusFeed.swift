import Foundation
import Synchronization

/// Hands every subscriber the current status first and then each change, in order. A continuation is never resumed under the lock: cancelling a waiting
/// subscriber holds its task's status lock while `onTermination` takes this one, and resuming that subscriber takes the two in the other order.
/// Publishing outside the lock keeps the order because only the runtime's actor publishes.
final class SyncStatusFeed: Sendable {
  private struct State {
    var current: SyncStatus
    var subscribers: [Int: AsyncStream<SyncStatus>.Continuation] = [:]
    var nextID = 0
    var isFinished = false
  }

  private let state: Mutex<State>

  init(_ initial: SyncStatus) {
    state = Mutex(State(current: initial))
  }

  var current: SyncStatus { state.withLock { $0.current } }

  func publish(_ status: SyncStatus) {
    let subscribers = state.withLock { state -> [AsyncStream<SyncStatus>.Continuation] in
      guard !state.isFinished, state.current != status else { return [] }
      state.current = status
      return Array(state.subscribers.values)
    }
    for subscriber in subscribers { subscriber.yield(status) }
  }

  func stream() -> AsyncStream<SyncStatus> {
    let (stream, continuation) = AsyncStream.makeStream(of: SyncStatus.self, bufferingPolicy: .unbounded)
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      return state.nextID
    }
    continuation.onTermination = { [weak self] _ in self?.remove(id) }
    let isFinished = state.withLock { state in
      continuation.yield(state.current)
      if !state.isFinished { state.subscribers[id] = continuation }
      return state.isFinished
    }
    if isFinished { continuation.finish() }
    return stream
  }

  func finish() {
    let subscribers = state.withLock { state in
      defer {
        state.subscribers = [:]
        state.isFinished = true
      }
      return Array(state.subscribers.values)
    }
    for subscriber in subscribers { subscriber.finish() }
  }

  private func remove(_ id: Int) {
    state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
  }
}
