import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import Synchronization

/// What a turn shows and records while it runs: one emitter and one event log for the whole turn (each model call has its own relay), the trace, and the
/// last request sent. Every event goes at once to each subscriber, which first receives everything this run showed; frames and the request are written
/// only when the engine flushes, at a round's end, at the end and every few seconds, since every store write wakes every observer.
final class ChatTurnStream: Sendable {
  private struct State {
    var emitter = TurnStreamEmitter()
    var log: TurnEventLog
    var trace: TurnTraceCollector
    var attempt: StructuredAttempt?
    /// Frames taken for a write that failed, sent again first.
    var unsent: [TurnFrame] = []
    var shown: [TurnStreamEvent] = []
    var subscribers: [UUID: AsyncStream<TurnStreamEvent>.Continuation] = [:]
    var isClosed = false
  }

  struct Pending: Sendable {
    let frames: [TurnFrame]
    let attempt: StructuredAttempt?

    var isEmpty: Bool { frames.isEmpty && attempt == nil }
  }

  /// The sequence of the last frame stored before this run began.
  let startSequence: Int
  private let state: Mutex<State>
  private let now: @Sendable () -> Double

  init(after lastSequence: Int, sources: [TurnTraceSource], now: @escaping @Sendable () -> Double) {
    startSequence = lastSequence
    self.now = now
    state = Mutex(State(log: TurnEventLog(after: lastSequence), trace: TurnTraceCollector(at: now(), carrying: sources)))
  }

  /// `earlier` comes first, then everything this run has shown, then each event as it is shown; it ends with the run.
  func subscribe(after earlier: [TurnStreamEvent] = []) -> AsyncStream<TurnStreamEvent> {
    let (events, continuation) = AsyncStream.makeStream(of: TurnStreamEvent.self)
    let id = UUID()
    let closed = state.withLock { state -> Bool in
      for event in earlier + state.shown { continuation.yield(event) }
      if !state.isClosed { state.subscribers[id] = continuation }
      return state.isClosed
    }
    if closed {
      continuation.finish()
    } else {
      continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
    }
    return events
  }

  func emit(_ event: TurnStreamEvent) {
    state.withLock { state in
      state.log.record(event)
      Self.show([event], in: &state)
    }
  }

  /// A relay's events, as the trace observes them before the emitter decides what reaches the stream (chat.service.ts:315).
  func relay(_ events: [ReplyStreamEvent]) {
    guard !events.isEmpty else { return }
    let at = now()
    state.withLock { state in
      for event in events { state.trace.observe(event, at: at) }
      let shown = state.emitter.relay(events)
      state.log.record(shown)
      Self.show(shown, in: &state)
    }
  }

  // chat.service.ts:316
  func supersede() {
    state.withLock { state in
      state.emitter.supersedeOnNextDelta()
      state.trace.supersedeOnNextWrite()
    }
  }

  func lookupStarted() {
    let at = now()
    state.withLock { $0.trace.lookupStarted(at: at) }
  }

  func lookupSettled(_ trace: ChatLookupTrace, tool: String) {
    let at = now()
    state.withLock { $0.trace.lookupSettled(tool: tool, args: trace.args, status: trace.status, at: at) }
  }

  func sent(_ attempt: StructuredAttempt) {
    state.withLock { $0.attempt = attempt }
  }

  var sources: [TurnTraceSource] { state.withLock { $0.trace.recorded } }

  func finishTrace() -> JSONValue {
    let at = now()
    return state.withLock { $0.trace.finish(at: at) }
  }

  /// The frames and request not yet written.
  func take() -> Pending {
    state.withLock { state in
      let pending = Pending(frames: state.unsent + state.log.takeFrames(), attempt: state.attempt)
      state.unsent = []
      state.attempt = nil
      return pending
    }
  }

  /// Gives back what a failed write took, so the next write stores it and no sequence is skipped.
  func requeue(_ pending: Pending) {
    state.withLock { state in
      state.unsent = pending.frames + state.unsent
      if state.attempt == nil { state.attempt = pending.attempt }
    }
  }

  func close() {
    let subscribers = state.withLock { state in
      state.isClosed = true
      defer { state.subscribers = [:] }
      return Array(state.subscribers.values)
    }
    for subscriber in subscribers { subscriber.finish() }
  }

  private func unsubscribe(_ id: UUID) {
    _ = state.withLock { $0.subscribers.removeValue(forKey: id) }
  }

  private static func show(_ events: [TurnStreamEvent], in state: inout State) {
    state.shown += events
    for event in events {
      for subscriber in state.subscribers.values { subscriber.yield(event) }
    }
  }
}
