import ShadowStore

/// One store's part of a read model, observed with `VaultStore.observeReads`.
public struct ObservedRead<Value: Sendable & Equatable>: Sendable {
  let store: VaultStore
  let read: @Sendable (ReadTransaction) throws -> Value

  public init(_ store: VaultStore, _ read: @escaping @Sendable (ReadTransaction) throws -> Value) {
    self.store = store
    self.read = read
  }

  fileprivate func run(at index: Int, into sink: AsyncStream<ObservationEvent>.Continuation) -> @Sendable () async -> Void {
    let store = store
    let read = read
    return {
      do {
        for try await value in store.observeReads(read) { sink.yield(.value(index, value)) }
        sink.yield(.finished)
      } catch {
        sink.yield(.failed(error))
      }
    }
  }
}

private enum ObservationEvent: Sendable {
  case value(Int, any Sendable)
  case failed(any Error)
  case finished
}

extension MemoirReadError {
  /// An observed read fails as the async read of the same model does.
  init(observed error: any Error) {
    switch error {
    case let error as MemoirReadError: self = error
    case let error as StoreError: self.init(error)
    case let error as FinanceError: self = .finance(error)
    default: self = .store(.aborted(error))
    }
  }
}

/// A read model spanning several stores: each store's part is observed on its own, and the model is rebuilt from the latest part of every store whenever
/// one of them changes, emitted once all parts have been read and again only when it differs.
enum ReadObservation {
  static func observe<A, Output: Sendable & Equatable>(_ a: ObservedRead<A>, _ build: @escaping @Sendable (A) throws -> Output) -> AsyncThrowingStream<Output, any Error> {
    merged([{ index, sink in a.run(at: index, into: sink) }]) { values in try build(try part(values[0])) }
  }

  static func observe<A, B, Output: Sendable & Equatable>(
    _ a: ObservedRead<A>, _ b: ObservedRead<B>, _ build: @escaping @Sendable (A, B) throws -> Output
  ) -> AsyncThrowingStream<Output, any Error> {
    merged([{ index, sink in a.run(at: index, into: sink) }, { index, sink in b.run(at: index, into: sink) }]) { values in
      try build(try part(values[0]), try part(values[1]))
    }
  }

  static func observe<A, B, C, Output: Sendable & Equatable>(
    _ a: ObservedRead<A>, _ b: ObservedRead<B>, _ c: ObservedRead<C>, _ build: @escaping @Sendable (A, B, C) throws -> Output
  ) -> AsyncThrowingStream<Output, any Error> {
    merged([{ index, sink in a.run(at: index, into: sink) }, { index, sink in b.run(at: index, into: sink) }, { index, sink in c.run(at: index, into: sink) }]) {
      values in try build(try part(values[0]), try part(values[1]), try part(values[2]))
    }
  }

  private static func part<Value>(_ value: any Sendable) throws -> Value {
    guard let typed = value as? Value else { throw MemoirReadError.store(.invalidChange("an observed part arrived with another type")) }
    return typed
  }

  private static func merged<Output: Sendable & Equatable>(
    _ parts: [@Sendable (Int, AsyncStream<ObservationEvent>.Continuation) -> @Sendable () async -> Void],
    _ build: @escaping @Sendable ([any Sendable]) throws -> Output
  ) -> AsyncThrowingStream<Output, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Output, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let task = Task {
      let (events, sink) = AsyncStream<ObservationEvent>.makeStream()
      await withTaskGroup(of: Void.self) { group in
        for (index, part) in parts.enumerated() {
          let run = part(index, sink)
          group.addTask { await run() }
        }
        var latest = [(any Sendable)?](repeating: nil, count: parts.count)
        var last: Output?
        for await event in events {
          switch event {
          case .value(let index, let value):
            latest[index] = value
            let values = latest.compactMap { $0 }
            guard values.count == parts.count else { continue }
            do {
              let output = try build(values)
              if output != last { continuation.yield(output) }
              last = output
            } catch {
              continuation.finish(throwing: MemoirReadError(observed: error))
              group.cancelAll()
              return
            }
          case .failed(let error):
            continuation.finish(throwing: MemoirReadError(observed: error))
            group.cancelAll()
            return
          case .finished:
            continuation.finish()
            group.cancelAll()
            return
          }
        }
        continuation.finish()
        group.cancelAll()
      }
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }
    return stream
  }
}
