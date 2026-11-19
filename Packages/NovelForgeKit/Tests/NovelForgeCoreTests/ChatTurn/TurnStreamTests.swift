import Foundation
import Testing

@testable import NovelForgeCore

@Suite("Turn stream", TestTimeLimit.quick)
struct TurnStreamTests {
  private static func element(_ source: String) throws -> ChangeSetElement {
    try #require(ChangeSetElement(source: source))
  }

  @Test func shouldPassAResetOnOnlyOnceSomethingWasShown() throws {
    var emitter = TurnStreamEmitter()
    #expect(emitter.relay(.reset).isEmpty)
    #expect(emitter.relay(.delta("a")) == [.delta("a")])
    #expect(emitter.relay(.reset) == [.reset])
    #expect(emitter.relay(.reset).isEmpty)
    let change = StreamedChange(index: 0, element: try Self.element(#"{"op":"entity.upsert","type":"character","name":"Mara"}"#))
    #expect(emitter.relay(.change(change)) == [.change(TurnChangeEvent(index: 0, op: "entity.upsert", label: "Mara", group: .people))])
  }

  @Test func shouldBlankALookupRoundsEarlierReplyOnlyWhenTheNextOneShowsSomething() {
    var emitter = TurnStreamEmitter()
    emitter.supersedeOnNextDelta()
    #expect(emitter.relay(.delta("first")) == [.delta("first")])
    emitter.supersedeOnNextDelta()
    #expect(emitter.relay(.reset) == [.reset])
    #expect(emitter.relay(.delta("again")) == [.delta("again")])
    emitter.supersedeOnNextDelta()
    #expect(emitter.relay(.delta("second")) == [.reset, .delta("second")])
    #expect(emitter.relay(.delta(" more")) == [.delta(" more")])
  }

  @Test func shouldNumberFramesAndMergeConsecutiveDeltasIntoTheFirstOnesFrame() throws {
    var log = TurnEventLog()
    let message = UUID()
    log.record(.user(message: message))
    log.record([.delta("a"), .delta(""), .delta("b")])
    log.record(.reset)
    log.record(.delta("c"))
    #expect(!log.mustFlush)
    let first = log.takeFrames()
    #expect(first.map(\.sequence) == [1, 2, 3, 4])
    #expect(first.map(\.decoded) == [.user(message: message), .delta("ab"), .reset, .delta("c")])
    log.record(.delta("d"))
    #expect(log.takeFrames().map(\.sequence) == [5])
    #expect(log.takeFrames().isEmpty)
  }

  @Test func shouldDropEverythingAfterTheTerminalFrame() {
    var log = TurnEventLog(after: 9)
    log.record(.delta("x"))
    log.record(.error(TurnFailure(code: "AI_001", message: "unreadable")))
    #expect(log.isClosed && log.mustFlush)
    log.record(.delta("late"))
    log.record(.done(reply: UUID()))
    let frames = log.takeFrames()
    #expect(frames.map(\.sequence) == [10, 11])
    #expect(frames.last?.decoded == .error(TurnFailure(code: "AI_001", message: "unreadable")))
    #expect(!log.mustFlush)
  }

  @Test func shouldReadEveryEventBackFromItsFrame() throws {
    let args = try #require(try OrderedJSON(parsing: #"{"b":1.5,"a":[true,null],"10":"x"}"#).objectValue)
    let events: [TurnStreamEvent] = [
      .user(message: UUID()), .lookup(TurnLookupEvent(round: 1, tool: "get_brief", args: args, status: .ok)), .delta("tab\t\"😀\u{2028}"),
      .change(TurnChangeEvent(index: 3, op: "promise.create", label: "Oath", group: .threads)), .reset, .done(reply: UUID()),
      .error(TurnFailure(code: "CHT_013", message: "")),
    ]
    for (index, event) in events.enumerated() {
      let frame = TurnFrame(sequence: index + 1, event)
      #expect(frame.event == event.name)
      #expect(frame.decoded == event)
    }
    let lookup = TurnFrame(sequence: 1, events[1])
    #expect(lookup.data == #"{"round":1,"tool":"get_brief","args":{"10":"x","b":1.5,"a":[true,null]},"status":"ok"}"#)
    guard case .lookup(let decoded)? = lookup.decoded else { throw TurnStreamTestError.notALookup }
    #expect(decoded.argumentsJSON == #"{"10":"x","b":1.5,"a":[true,null]}"#)
  }

  @Test func shouldStepOverAFrameWhoseDataDoesNotReadAsItsEvent() {
    #expect(TurnFrame(sequence: 1, event: .delta, data: #"{"text":""}"#).decoded == nil)
    #expect(TurnFrame(sequence: 1, event: .user, data: #"{"message":"not a uuid"}"#).decoded == nil)
    #expect(TurnFrame(sequence: 1, event: .change, data: #"{"index":-1,"op":"a","label":"a","group":"people"}"#).decoded == nil)
    #expect(TurnFrame(sequence: 1, event: .lookup, data: #"{"round":0,"tool":"t","args":{},"status":"waiting"}"#).decoded == nil)
    #expect(TurnFrame(sequence: 1, event: .done, data: "not json").decoded == nil)
    #expect(TurnFrame(sequence: 1, event: .error, data: #"{"code":"AI_001"}"#).decoded == nil)
  }

  @Test func shouldNeverStepOverAResetWhateverItsData() {
    #expect(TurnFrame(sequence: 1, event: .reset, data: "not json").decoded == .reset)
    #expect(TurnFrame(sequence: 1, event: .reset, data: "").decoded == .reset)
  }

  @Test func shouldGroupAnEntityByItsOwnTypeOnlyWhereTheReferenceAlsoReadsThePrototype() throws {
    for type in ["constructor", "toString", "__proto__", "hasOwnProperty"] {
      let event = describeStreamedChange(index: 0, element: try Self.element(#"{"op":"entity.upsert","type":"\#(type)","name":"n"}"#))
      #expect(event.group == .other)
    }
  }
}

private enum TurnStreamTestError: Error {
  case notALookup
}
