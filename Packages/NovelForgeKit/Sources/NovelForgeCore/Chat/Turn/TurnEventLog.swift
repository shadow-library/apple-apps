/// The writing half of a turn's stream, port of the reference's `TurnEventLog` (apps/novel-forge-server/src/modules/refinement/turn-event-log.ts:66): it numbers
/// the frames and hands them over in order, consecutive deltas merged into one frame. When to take a batch is the caller's: the reference gathers frames for
/// 100 ms and writes a terminal frame at once, which `mustFlush` reports.
struct TurnEventLog: Sendable {
  private enum Pending {
    case delta(sequence: Int, text: String)
    case event(sequence: Int, TurnStreamEvent)
  }

  private(set) var isClosed = false
  private(set) var lastSequence: Int
  private var pending: [Pending] = []

  /// A resumed turn goes on numbering after the frames it already stored.
  init(after lastSequence: Int = 0) {
    self.lastSequence = lastSequence
  }

  /// Everything after `done` or `error` is dropped (turn-event-log.ts:94-115).
  mutating func record(_ event: TurnStreamEvent) {
    guard !isClosed else { return }
    if case .delta(let text) = event {
      guard !text.isEmpty else { return }
      if case .delta(let sequence, let earlier)? = pending.last {
        pending[pending.count - 1] = .delta(sequence: sequence, text: earlier + text)
        return
      }
      lastSequence += 1
      pending.append(.delta(sequence: lastSequence, text: text))
      return
    }
    lastSequence += 1
    pending.append(.event(sequence: lastSequence, event))
    if event.name.isTerminal { isClosed = true }
  }

  mutating func record(_ events: [TurnStreamEvent]) {
    for event in events { record(event) }
  }

  /// A batch holding `done` or `error` is written at once (turn-event-log.ts:110).
  var mustFlush: Bool { isClosed && !pending.isEmpty }

  var hasPending: Bool { !pending.isEmpty }

  // turn-event-log.ts:117
  mutating func takeFrames() -> [TurnFrame] {
    let frames = pending.map { entry in
      switch entry {
      case .delta(let sequence, let text): TurnFrame(sequence: sequence, .delta(text))
      case .event(let sequence, let event): TurnFrame(sequence: sequence, event)
      }
    }
    pending = []
    return frames
  }
}
