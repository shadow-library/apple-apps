/// Turns what the relay shows into the turn's stream events, port of the reference's `EmitterRelay` (apps/novel-forge-server/src/modules/refinement/chat-turn-emitter.ts:110).
/// A reset reaches the stream only once something was shown, and a lookup round's replacement reply blanks the earlier one only when its own text or changes arrive.
struct TurnStreamEmitter: Sendable {
  private var shown = false
  private var supersede = false

  // chat-turn-emitter.ts:121
  mutating func relay(_ event: ReplyStreamEvent) -> [TurnStreamEvent] {
    switch event {
    case .delta(let text): show() + [.delta(text)]
    case .change(let change): show() + [.change(describeStreamedChange(index: change.index, element: change.element))]
    case .reset: reset()
    }
  }

  mutating func relay(_ events: [ReplyStreamEvent]) -> [TurnStreamEvent] {
    events.flatMap { relay($0) }
  }

  // chat-turn-emitter.ts:147
  mutating func supersedeOnNextDelta() {
    supersede = shown
  }

  // chat-turn-emitter.ts:151
  private mutating func show() -> [TurnStreamEvent] {
    let voided = supersede ? reset() : []
    shown = true
    return voided
  }

  // chat-turn-emitter.ts:156
  private mutating func reset() -> [TurnStreamEvent] {
    supersede = false
    guard shown else { return [] }
    shown = false
    return [.reset]
  }
}
