import Observation

enum Loadable<Value: Sendable & Equatable>: Equatable {
  case loading
  case loaded(Value)
  case failed(PresentedError)

  var value: Value? {
    guard case .loaded(let value) = self else { return nil }
    return value
  }
}

@MainActor
@Observable
final class ReadObserver<Value: Sendable & Equatable> {
  private(set) var state = Loadable<Value>.loading

  func run(_ makeStream: () -> AsyncThrowingStream<Value, any Error>) async {
    if case .failed = state { state = .loading }
    do {
      for try await value in makeStream() { state = .loaded(value) }
    } catch is CancellationError {
      return
    } catch {
      state = .failed(PresentedError(error))
    }
  }
}
