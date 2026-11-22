import Observation

public enum Loadable<Value: Sendable & Equatable>: Equatable {
  case loading
  case loaded(Value)
  case failed(PresentedError)

  public var value: Value? {
    guard case .loaded(let value) = self else { return nil }
    return value
  }

  public func map<Other: Sendable & Equatable>(_ transform: (Value) -> Other) -> Loadable<Other> {
    switch self {
    case .loading: .loading
    case .loaded(let value): .loaded(transform(value))
    case .failed(let error): .failed(error)
    }
  }
}

@MainActor
@Observable
public final class ReadObserver<Value: Sendable & Equatable> {
  public private(set) var state = Loadable<Value>.loading

  public init() {}

  public func run(_ makeStream: () -> AsyncThrowingStream<Value, any Error>, onValue: (Value) -> Void = { _ in }) async {
    if case .failed = state { state = .loading }
    do {
      for try await value in makeStream() {
        if state.value != value { state = .loaded(value) }
        onValue(value)
      }
    } catch is CancellationError {
      return
    } catch {
      state = .failed(PresentedError(error))
    }
  }
}
