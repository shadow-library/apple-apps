import ShadowStore
import Synchronization

final class AttemptControl: Sendable {
  private struct State {
    var stop: LocalStop?
    var crashed = false
    var writes = 0
    var cancelStep: (@Sendable () -> Void)?
  }

  let job: EntityRef
  private let state = Mutex(State())

  init(job: EntityRef) {
    self.job = job
  }

  var stop: LocalStop? { state.withLock { $0.stop } }

  var isCrashed: Bool { state.withLock { $0.crashed } }

  func attach(_ cancel: @escaping @Sendable () -> Void) {
    let stopped = state.withLock { state in
      state.cancelStep = cancel
      return state.stop != nil || state.crashed
    }
    if stopped { cancel() }
  }

  func countWrite() -> Int {
    state.withLock { state in
      defer { state.writes += 1 }
      return state.writes
    }
  }

  func detach() {
    state.withLock { $0.cancelStep = nil }
  }

  @discardableResult
  func stop(_ reason: LocalStop) -> Bool {
    let (first, cancel) = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
      guard state.stop == nil else { return (false, nil) }
      state.stop = reason
      return (true, state.cancelStep)
    }
    cancel?()
    return first
  }

  /// A step left running keeps its open transaction, which cancelling it would roll back.
  func crash(cancellingStep: Bool = true) {
    let cancel = state.withLock { state in
      state.crashed = true
      return state.cancelStep
    }
    if cancellingStep { cancel?() }
  }
}
