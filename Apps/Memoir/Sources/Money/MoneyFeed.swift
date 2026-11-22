import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowCore

/// One observed read that a screen restarts when what it asks for changes (the day, the range, the search). A value from a stream that was replaced is
/// dropped, so a slow earlier read never overwrites a newer one.
@MainActor
@Observable
final class MoneyFeed<Value: Sendable & Equatable> {
  private(set) var state = Loadable<Value>.loading
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  /// Restarts the feed on a new stream, in a task of its own.
  func follow(_ makeStream: @escaping () -> AsyncThrowingStream<Value, any Error>) {
    task?.cancel()
    let current = advance()
    task = Task { [weak self] in await self?.read(makeStream(), generation: current) }
  }

  /// Reads the stream in the caller's task until it ends or the task is cancelled, handing each value it takes to `onValue`.
  func consume(_ stream: AsyncThrowingStream<Value, any Error>, onValue: @MainActor (Value) -> Void = { _ in }) async {
    await read(stream, generation: advance(), onValue: onValue)
  }

  func stop() {
    task?.cancel()
    task = nil
    generation += 1
  }

  private func advance() -> Int {
    generation += 1
    if case .failed = state { state = .loading }
    return generation
  }

  private func read(_ stream: AsyncThrowingStream<Value, any Error>, generation current: Int, onValue: @MainActor (Value) -> Void = { _ in }) async {
    do {
      for try await value in stream {
        guard generation == current, !Task.isCancelled else { return }
        if state.value != value { state = .loaded(value) }
        onValue(value)
      }
    } catch is CancellationError {
      return
    } catch {
      guard generation == current, !Task.isCancelled else { return }
      state = .failed(MoneyErrors.read(error))
    }
  }

  /// A failure of what drives the feed, such as the account's day; a cancellation shows nothing.
  func fail(_ error: any Error) {
    guard !(error is CancellationError), !Task.isCancelled else { return }
    stop()
    state = .failed(MoneyErrors.read(error))
  }
}

enum MoneyErrors {
  /// A read that failed: the shell's store headline when the store could not be read, the generic one otherwise, with the code underneath.
  static func read(_ error: any Error) -> PresentedError {
    switch error {
    case let error as MemoirReadError:
      guard case .store = error else { return PresentedError(headline: PresentedError.genericHeadline, detail: error.code) }
      return PresentedError(headline: PresentedError.storeHeadline, detail: error.code)
    case let error as any ShadowError: return PresentedError(headline: PresentedError.genericHeadline, detail: error.code)
    default: return PresentedError(error)
    }
  }
}
