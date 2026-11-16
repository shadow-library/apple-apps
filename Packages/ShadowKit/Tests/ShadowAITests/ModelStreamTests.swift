import Foundation
import Synchronization
import Testing

@testable import ShadowAI

@Suite("ModelStream", .timeLimit(.minutes(1)))
struct ModelStreamTests {
  private static let usage = TokenUsage(input: 12, output: 3, cacheRead: 100)
  private static let script: [ModelEvent] = [
    .started(requestID: "req_1", generationID: "gen_1"), .textDelta("Hello"), .textDelta(", world"),
    .finished(usage: usage, reportedCost: Cost(nanoUSD: 42), stop: .endTurn),
  ]

  private static func playing(_ events: [ModelEvent], then error: ModelError? = nil) -> ModelStream {
    ModelStream { continuation throws(ModelError) in
      for event in events { try continuation.yield(event) }
      if let error { throw error }
    }
  }

  private static func drain(_ stream: ModelStream) async -> (events: [ModelEvent], error: ModelError?) {
    var events: [ModelEvent] = []
    do throws(ModelError) {
      for try await event in stream { events.append(event) }
      return (events, nil)
    } catch {
      return (events, error)
    }
  }

  @Test("should deliver events in order")
  func deliversInOrder() async {
    let outcome = await Self.drain(Self.playing(Self.script))
    #expect(outcome.events == Self.script)
    #expect(outcome.error == nil)
  }

  @Test("should surface a thrown model error typed after the events before it")
  func surfacesTypedError() async {
    let outcome = await Self.drain(Self.playing([.started(requestID: nil, generationID: nil), .textDelta("Hal")], then: .midStream(code: "overloaded_error", message: "busy")))
    #expect(outcome.events == [.started(requestID: nil, generationID: nil), .textDelta("Hal")])
    #expect(outcome.error == .midStream(code: "overloaded_error", message: "busy"))
  }

  @Test("should surface an error raised before any event")
  func surfacesEarlyError() async {
    let outcome = await Self.drain(Self.playing([], then: .authentication))
    #expect(outcome.events.isEmpty)
    #expect(outcome.error == .authentication)
  }

  @Test(
    "should convert foreign errors from a wrapped stream",
    arguments: [
      (URLError(.networkConnectionLost) as any Error, ModelError.transport(.networkConnectionLost)),
      (CancellationError(), .cancelled),
      (ModelError.overloaded(retryAfter: nil), .overloaded(retryAfter: nil)),
    ]
  )
  func convertsForeignErrors(error: any Error, expected: ModelError) async {
    let (events, continuation) = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    continuation.yield(.started(requestID: "r", generationID: nil))
    continuation.finish(throwing: error)
    let outcome = await Self.drain(ModelStream(events))
    #expect(outcome.events == [.started(requestID: "r", generationID: nil)])
    #expect(outcome.error == expected)
  }

  @Test("should convert an unknown error into an unreadable reply")
  func convertsUnknownError() async {
    struct Garbled: Error {}
    let (events, continuation) = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    continuation.finish(throwing: Garbled())
    guard case .malformedResponse = await Self.drain(ModelStream(events)).error else {
      Issue.record("expected malformedResponse")
      return
    }
  }

  @Test("should end with cancelled and cancel the producer when the consumer is cancelled")
  func cancelsWithConsumer() async {
    let delivered = Signal()
    let producerStopped = Signal()
    let producerSawCancellation = Mutex(false)
    let stream = ModelStream { continuation throws(ModelError) in
      try continuation.yield(.started(requestID: "r", generationID: nil))
      try? await Task.sleep(for: .seconds(600))
      producerSawCancellation.withLock { $0 = Task.isCancelled }
      producerStopped.fire()
    }
    let consumer = Task {
      var events: [ModelEvent] = []
      do throws(ModelError) {
        for try await event in stream {
          events.append(event)
          delivered.fire()
        }
        return Result<[ModelEvent], ModelError>.success(events)
      } catch {
        return .failure(error)
      }
    }

    await delivered.wait()
    consumer.cancel()

    #expect(await consumer.value == .failure(.cancelled))
    await producerStopped.wait()
    #expect(producerSawCancellation.withLock { $0 })
  }

  @Test("should end with cancelled when the consumer is already cancelled")
  func cancelsBeforeFirstEvent() async {
    let gate = Signal()
    let consumer = Task {
      await gate.wait()
      return await Self.drain(Self.playing(Self.script)).error
    }
    consumer.cancel()
    gate.fire()
    #expect(await consumer.value == .cancelled)
  }

  @Test("should cancel the producer when the consumer breaks out of the loop")
  func cancelsOnBreak() async throws {
    let producerStopped = Signal()
    let producerSawCancellation = Mutex(false)
    let stream = ModelStream { continuation throws(ModelError) in
      try continuation.yield(.started(requestID: "r", generationID: nil))
      try? await Task.sleep(for: .seconds(600))
      producerSawCancellation.withLock { $0 = Task.isCancelled }
      producerStopped.fire()
    }

    for try await event in stream {
      #expect(event == .started(requestID: "r", generationID: nil))
      break
    }

    await producerStopped.wait()
    #expect(producerSawCancellation.withLock { $0 })
    withExtendedLifetime(stream) {}
  }

  @Test("should stop a producer that keeps yielding after the consumer left")
  func stopsYieldingAfterBreak() async throws {
    let producerResult = Mutex<ModelError?>(nil)
    let producerStopped = Signal()
    let first = Signal()
    let stream = ModelStream { continuation throws(ModelError) in
      do throws(ModelError) {
        try continuation.yield(.textDelta("a"))
        await first.wait()
        while true { try continuation.yield(.textDelta("more")) }
      } catch {
        producerResult.withLock { $0 = error }
        producerStopped.fire()
        throw error
      }
    }

    for try await _ in stream { break }
    first.fire()

    await producerStopped.wait()
    #expect(producerResult.withLock { $0 } == .cancelled)
    withExtendedLifetime(stream) {}
  }

  @Test("should cancel a wrapped stream's source when the consumer breaks out")
  func cancelsWrappedSource() async throws {
    let terminated = Signal()
    let (events, continuation) = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    continuation.onTermination = { _ in terminated.fire() }
    continuation.yield(.started(requestID: nil, generationID: nil))

    for try await _ in ModelStream(events) { break }

    await terminated.wait()
    guard case .terminated = continuation.yield(.textDelta("late")) else {
      Issue.record("expected the source to be terminated")
      return
    }
  }

  private static func counting(_ runs: RunCounter) -> ModelStream {
    ModelStream { continuation throws(ModelError) in
      runs.increment()
      for event in script { try continuation.yield(event) }
    }
  }

  @Test("should never run the builder of a stream that is built and dropped")
  func staysIdleWhenDropped() async throws {
    let runs = RunCounter()
    _ = Self.counting(runs)
    do { _ = Self.counting(runs) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(runs.value == 0)
  }

  @Test("should not start on creating an iterator, and an unused iterator leaves the stream usable")
  func staysIdleWithUnusedIterator() async throws {
    let runs = RunCounter()
    let stream = Self.counting(runs)
    _ = stream.makeAsyncIterator()
    try await Task.sleep(for: .milliseconds(50))
    #expect(runs.value == 0)

    #expect(try await stream.collect().text == "Hello, world")
    #expect(runs.value == 1)
  }

  @Test("should never start a stream whose consumer is cancelled before its first next")
  func neverStartsForCancelledConsumer() async throws {
    let runs = RunCounter()
    let stream = Self.counting(runs)
    let gate = Signal()
    let consumer = Task {
      await gate.wait()
      return await Self.drain(stream)
    }
    consumer.cancel()
    gate.fire()

    let outcome = await consumer.value
    #expect(outcome.error == .cancelled)
    #expect(outcome.events.isEmpty)
    try await Task.sleep(for: .milliseconds(50))
    #expect(runs.value == 0)
    #expect(await Self.drain(stream).events.isEmpty)
  }

  @Test("should run once and come back empty when iterated a second time")
  func isSinglePass() async throws {
    let runs = RunCounter()
    let stream = Self.counting(runs)

    #expect(try await stream.collect().text == "Hello, world")
    let second = await Self.drain(stream)

    #expect(second.events.isEmpty)
    #expect(second.error == nil)
    #expect(runs.value == 1)
  }

  @Test("should collect text, usage, cost, stop and ids")
  func collectsResponse() async throws {
    let response = try await Self.playing([.retrying(attempt: 1, delay: .seconds(1), cause: .overloaded(retryAfter: nil), requestID: "req_0", generationID: nil)] + Self.script)
      .collect()
    #expect(
      response == ModelResponse(text: "Hello, world", usage: Self.usage, reportedCost: Cost(nanoUSD: 42), stop: .endTurn, requestID: "req_1", generationID: "gen_1")
    )
  }

  @Test("should collect a refusal as a finished response")
  func collectsRefusal() async throws {
    let events: [ModelEvent] = [.started(requestID: "r", generationID: nil), .finished(usage: .zero, reportedCost: nil, stop: .refusal(category: "cyber"))]
    let response = try await Self.playing(events).collect()
    #expect(response.stop == .refusal(category: "cyber"))
    #expect(response.text.isEmpty)
  }

  @Test("should fail to collect a stream that never finished")
  func rejectsMissingFinish() async {
    await #expect {
      try await Self.playing([.started(requestID: "r", generationID: nil), .textDelta("half")]).collect()
    } throws: { error in
      guard case .malformedResponse = error as? ModelError else { return false }
      return true
    }
  }

  @Test("should fail to collect a stream that sends events after finishing")
  func rejectsEventsAfterFinish() async {
    await #expect {
      try await Self.playing(Self.script + [.textDelta("extra")]).collect()
    } throws: { error in
      guard case .malformedResponse = error as? ModelError else { return false }
      return true
    }
  }

  @Test("should pass a typed error through collect")
  func collectsTypedError() async {
    await #expect(throws: ModelError.insufficientCredits) {
      try await Self.playing([], then: .insufficientCredits).collect()
    }
  }
}
