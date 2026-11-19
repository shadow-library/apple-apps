import Foundation
import Testing

@testable import NovelForgeCore

private struct Replayed {
  var relay: [[TurnRelayFixture.Value]] = []
  var turn: [[TurnRelayFixture.Value]] = []
  var frames: [TurnRelayFixture.Frame] = []

  var isEmpty: Bool { relay.isEmpty && turn.isEmpty && frames.isEmpty }
}

/// Plays the fixture's ops the way the reference turn wires them: a relay per model call, one emitter and one event log per turn.
private struct TurnReplay {
  private var relay = ReplyStreamRelay()
  private var emitter = TurnStreamEmitter()
  private var log = TurnEventLog()

  mutating func play(_ op: TurnRelayFixture.Op) throws -> Replayed {
    var relayed: [ReplyStreamEvent] = []
    var frames: [TurnFrame] = []
    switch op {
    case .call(let unrestricted): relay = ReplyStreamRelay(refuses: unrestricted ? fixtureVeto : nil)
    case .push(let chunk): relayed = relay.push(chunk)
    case .restart: relayed = relay.restart()
    case .settle(let raw): relayed = relay.settle(raw: raw)
    case .supersede: emitter.supersedeOnNextDelta()
    case .lookup(let round, let tool, let args, let status):
      let arguments = try #require(try OrderedJSON(parsing: args).objectValue)
      log.record(.lookup(TurnLookupEvent(round: round, tool: tool, args: arguments, status: try #require(TurnLookupStatus(rawValue: status)))))
    case .user(let message): log.record(.user(message: try #require(UUID(uuidString: message))))
    case .flush: frames = log.takeFrames()
    case .done(let reply):
      log.record(.done(reply: try #require(UUID(uuidString: reply))))
      frames = log.takeFrames()
    case .error(let code, let message):
      log.record(.error(TurnFailure(code: code, message: message)))
      frames = log.takeFrames()
    }
    let turnEvents = emitter.relay(relayed)
    log.record(turnEvents)
    return Replayed(
      relay: relayed.map(fixtureValues), turn: turnEvents.map(fixtureValues),
      frames: frames.map { TurnRelayFixture.Frame(sequence: $0.sequence, event: $0.event.rawValue, data: $0.data) })
  }
}

@Suite("Turn relay parity", TestTimeLimit.standard)
struct TurnRelayParityTests {
  @Test func shouldEmitWhatTheReferenceRelayEmitterAndEventLogEmitForEveryScriptedTurn() throws {
    let fixture = try TurnRelayFixture.load()
    #expect(fixture.scenarios.count == 160)
    var failures: [String] = []
    for (number, scenario) in fixture.scenarios.enumerated() {
      var replay = TurnReplay()
      let expected = Dictionary(uniqueKeysWithValues: scenario.steps.map { ($0.index, $0) })
      for (index, op) in scenario.ops.enumerated() {
        let replayed = try replay.play(op)
        guard let step = expected[index] else {
          if !replayed.isEmpty { failures.append("scenario \(number) op \(index): emitted \(replayed) where the reference emitted nothing") }
          continue
        }
        let framesMatch =
          replayed.frames.count == step.frames.count
          && zip(replayed.frames, step.frames).allSatisfy { $0.sequence == $1.sequence && $0.event == $1.event && $0.data.jsEquals($1.data) }
        if !jsEqual(replayed.relay, step.relay) || !jsEqual(replayed.turn, step.turn) || !framesMatch {
          failures.append("scenario \(number) op \(index) \(op): expected \(step.relay) \(step.turn) \(step.frames), got \(replayed)")
        }
      }
    }
    #expect(failures.isEmpty, "\(failures.count) mismatches; first: \(failures.prefix(3))")
  }

  @Test func shouldDescribeEachChangeAsTheReferenceDoes() throws {
    let fixture = try TurnRelayFixture.load()
    for row in fixture.describe {
      let element = try #require(ChangeSetElement(source: row.element))
      let event = describeStreamedChange(index: row.index, element: element)
      #expect(event.index == row.index)
      #expect(event.op.jsEquals(row.op), "\(row.element)")
      #expect(event.label.jsEquals(row.label), "\(row.element): \(event.label) vs \(row.label)")
      #expect(event.group.rawValue == row.group, "\(row.element)")
    }
  }

  @Test func shouldReleaseAnUnrestrictedReplyAtTheReferencesSentenceEnds() throws {
    let fixture = try TurnRelayFixture.load()
    for row in fixture.sentenceEnds {
      let quoted = OrderedJSON.string(row.text).jsonText
      var relay = ReplyStreamRelay(refuses: { _ in false })
      let released = relay.push("{\"reply\":\(quoted)").compactMap { event -> String? in
        guard case .delta(let text) = event else { return nil }
        return text
      }
      #expect(released.count == row.released.count && zip(released, row.released).allSatisfy { $0.jsEquals($1) }, "\(row.text.debugDescription)")
    }
  }
}
