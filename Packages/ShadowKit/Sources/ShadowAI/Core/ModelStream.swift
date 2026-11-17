import Synchronization

/// One model call's events. Single-pass and lazy: the call starts on the first `next()`, and a later iterator sees the stream already ended.
public struct ModelStream: AsyncSequence, Sendable {
  public typealias Element = ModelEvent
  public typealias Failure = ModelError
  public typealias Build = @Sendable (Continuation) async throws(ModelError) -> Void

  private typealias Events = AsyncThrowingStream<ModelEvent, any Error>

  public struct Continuation: Sendable {
    fileprivate let base: AsyncThrowingStream<ModelEvent, any Error>.Continuation

    /// Throws `cancelled` once the consumer has stopped listening.
    public func yield(_ event: ModelEvent) throws(ModelError) {
      switch base.yield(event) {
      case .enqueued, .dropped: return
      case .terminated: throw .cancelled
      @unknown default: return
      }
    }

    public func finish() {
      base.finish()
    }
  }

  public struct Iterator: AsyncIteratorProtocol {
    private enum Phase {
      case idle
      case streaming
      case finished
      case done
    }

    private var base: AsyncThrowingStream<ModelEvent, any Error>.Iterator
    private let continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation
    private let launcher: Launcher
    private var terminator: Terminator?
    private var phase = Phase.idle

    fileprivate init(base: AsyncThrowingStream<ModelEvent, any Error>.Iterator, continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation, launcher: Launcher) {
      self.base = base
      self.continuation = continuation
      self.launcher = launcher
    }

    public mutating func next() async throws(ModelError) -> ModelEvent? {
      try await next(isolation: #isolation)
    }

    public mutating func next(isolation actor: isolated (any Actor)?) async throws(ModelError) -> ModelEvent? {
      switch phase {
      case .done:
        return nil
      case .idle:
        terminator = Terminator(continuation)
        phase = .streaming
        if Task.isCancelled { throw end(with: .cancelled) }
        launcher.start(continuation)
      case .streaming:
        if Task.isCancelled { throw end(with: .cancelled) }
      case .finished:
        break
      }
      let event: ModelEvent?
      do {
        event = try await base.next(isolation: actor)
      } catch {
        throw end(with: ModelError(converting: error))
      }
      guard let event else {
        if phase == .streaming, Task.isCancelled { throw end(with: .cancelled) }
        phase = .done
        return nil
      }
      if case .finished = event { phase = .finished }
      return event
    }

    private mutating func end(with error: ModelError) -> ModelError {
      phase = .done
      terminator?.terminate()
      return error
    }
  }

  fileprivate final class Terminator: Sendable {
    private let continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation

    init(_ continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation) {
      self.continuation = continuation
    }

    func terminate() {
      continuation.finish()
    }

    deinit {
      continuation.finish()
    }
  }

  fileprivate final class Launcher: Sendable {
    private enum State {
      case idle(Build)
      case starting
      case running(Task<Void, Never>)
      case ended
    }

    private let state: Mutex<State>
    private let onStart: @Sendable () -> Void

    init(_ build: @escaping Build, onStart: @escaping @Sendable () -> Void) {
      state = Mutex(.idle(build))
      self.onStart = onStart
    }

    func start(_ continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation) {
      let build: Build? = state.withLock { state in
        guard case .idle(let build) = state else { return nil }
        state = .starting
        return build
      }
      guard let build else { return }
      onStart()
      let producer = Task {
        do throws(ModelError) {
          try await build(Continuation(base: continuation))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      let ended = state.withLock { state in
        guard case .starting = state else { return true }
        state = .running(producer)
        return false
      }
      if ended { producer.cancel() }
    }

    func end() {
      let producer: Task<Void, Never>? = state.withLock { state in
        defer { state = .ended }
        guard case .running(let producer) = state else { return nil }
        return producer
      }
      producer?.cancel()
    }
  }

  private let events: Events
  private let continuation: Events.Continuation
  private let launcher: Launcher

  /// Any error that is not a `ModelError` is converted with `ModelError(converting:)`.
  public init(_ events: AsyncThrowingStream<ModelEvent, any Error>) {
    self.init { continuation throws(ModelError) in
      do {
        for try await event in events { try continuation.yield(event) }
      } catch {
        throw ModelError(converting: error)
      }
    }
  }

  /// Runs `build` in a task started on the first `next()` and cancelled when the consumer stops, breaks out or is cancelled; returning finishes the stream.
  /// `onStart` runs synchronously in that first `next()`, only when `build` is then launched, and `build` always runs once launched, even if cancelled.
  public init(onStart: @escaping @Sendable () -> Void = {}, _ build: @escaping Build) {
    let (events, continuation) = Events.makeStream()
    let launcher = Launcher(build, onStart: onStart)
    continuation.onTermination = { _ in launcher.end() }
    self.events = events
    self.continuation = continuation
    self.launcher = launcher
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(base: events.makeAsyncIterator(), continuation: continuation, launcher: launcher)
  }

  /// Throws `malformedResponse` when the stream ends without `finished` or sends anything after it.
  /// A caller that must keep partial text when the call fails iterates the stream instead, since a thrown error discards it.
  public func collect() async throws(ModelError) -> ModelResponse {
    var text = ""
    var requestID: String?
    var generationID: String?
    var outcome: (usage: TokenUsage, reportedCost: Cost?, stop: StopReason)?
    for try await event in self {
      guard outcome == nil else { throw .malformedResponse("The provider sent more after the reply finished.") }
      switch event {
      case .started(let request, let generation):
        requestID = request
        generationID = generation
      case .textDelta(let delta):
        text += delta
      case .retrying:
        continue
      case .finished(let usage, let reportedCost, let stop):
        outcome = (usage, reportedCost, stop)
      }
    }
    guard let outcome else { throw .malformedResponse("The reply ended before it finished.") }
    return ModelResponse(text: text, usage: outcome.usage, reportedCost: outcome.reportedCost, stop: outcome.stop, requestID: requestID, generationID: generationID)
  }
}
