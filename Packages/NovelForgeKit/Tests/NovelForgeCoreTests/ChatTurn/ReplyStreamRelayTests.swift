import Foundation
import ShadowAI
import ShadowCore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private func deltas(_ events: [ReplyStreamEvent]) -> [String] {
  events.compactMap { event in
    guard case .delta(let text) = event else { return nil }
    return text
  }
}

private func changeOps(_ events: [ReplyStreamEvent]) -> [String] {
  events.compactMap { event in
    guard case .change(let change) = event else { return nil }
    return "\(change.index):\(change.element.op)"
  }
}

private let replyAndCountSchema: JSONValue = [
  "type": "object", "required": ["reply", "n"], "additionalProperties": false,
  "properties": ["reply": ["type": "string"], "n": ["type": "integer"]],
]

@Suite("Reply stream relay", TestTimeLimit.quick)
struct ReplyStreamRelayTests {
  @Test func shouldStreamTheReplyAsItIsDecodedAcrossEscapeAndSurrogateBoundaries() {
    var relay = ReplyStreamRelay()
    var shown: [String] = []
    for chunk in [#"{"chang"#, #"eSet":[],"re"#, #"ply":"a\"#, #"u00"#, #"e9 \ud83d"#, #"\ude00 b\"#, #"n"#, #"c"}"#] { shown += deltas(relay.push(chunk)) }
    #expect(shown == ["a", "é ", "😀 b", "\n", "c"])
    #expect(relay.replyFound)
  }

  @Test func shouldShowNothingForAnAnswerWithoutAReplyAndNeverAnEmptyDelta() {
    var relay = ReplyStreamRelay()
    #expect(relay.push(#"{"question":"which?","reply":""#).isEmpty)
    #expect(relay.push(#""}"#).isEmpty)
    #expect(relay.settle(raw: #"{"question":"which?","reply":""}"#).isEmpty)

    var silent = ReplyStreamRelay()
    #expect(silent.push(#"{"lookups":[{"tool":"get_brief"}]}"#).isEmpty)
    #expect(!silent.replyFound)
  }

  @Test func shouldEmitEachChangeWhenItClosesAndNumberThemAgainAfterAReset() {
    var relay = ReplyStreamRelay()
    let first = relay.push(#"{"reply":"r","changeSet":[{"op":"a"},{"op":"#)
    #expect(changeOps(first) == ["0:a"])
    #expect(changeOps(relay.push(#""b"}]}"#)) == ["1:b"])
    #expect(relay.restart() == [.reset])
    #expect(relay.restart().isEmpty)
    #expect(changeOps(relay.push(#"{"changeSet":[{"op":"c"}],"reply":"s"}"#)) == ["0:c"])
  }

  @Test func shouldSettleQuietlyOnlyWhenTheAnswerHoldsWhatWasShown() {
    var same = ReplyStreamRelay()
    _ = same.push(#"{"reply":"Hi","changeSet":[{"op":"a","x":1}]}"#)
    #expect(same.settle(raw: #"{ "reply" : "Hi" , "changeSet" : [ { "op" : "a" , "x" : 1.0 } ] }"#).isEmpty)

    var reply = ReplyStreamRelay()
    _ = reply.push(#"{"reply":"Hi"}"#)
    #expect(reply.settle(raw: #"{"reply":"Hi!"}"#) == [.reset])

    var changes = ReplyStreamRelay()
    _ = changes.push(#"{"reply":"Hi","changeSet":[{"op":"a"}]}"#)
    #expect(changes.settle(raw: #"{"reply":"Hi","changeSet":[{"op":"a"},{"op":"b"}]}"#) == [.reset])

    var composed = ReplyStreamRelay()
    _ = composed.push(#"{"reply":"é"}"#)
    #expect(composed.settle(raw: #"{"reply":"é"}"#) == [.reset])
  }

  @Test func shouldResetWhenTheAcceptedAnswerIsALaterValueOfTheShownAttempt() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(#"{"reply":"first"}"#)
    provider.enqueueReply(#"{"reply":"draft"} {"reply":"final","n":1}"#)
    let request = ModelRequest(model: "m", system: [ContextSegment(text: "s")], messages: [.user("go")], maxOutputTokens: 256)
    var relay = ReplyStreamRelay()
    var shown: [ReplyStreamEvent] = []

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).stream(request, name: "turn", schema: replyAndCountSchema) {
      shown += relay.receive($0)
    }
    shown += relay.settle(result)

    #expect(result.wasRepaired)
    #expect(shown.filter { $0 == .reset }.count == 2)
    #expect(deltas(shown).joined() == "firstdraft")
    #expect(shown.last == .reset)
  }

  @Test func shouldLeaveShownTextAloneWhenTheCallFails() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueue([.event(.started(requestID: nil, generationID: nil)), .text(#"{"reply":"Half a tho"#), .failure(.midStream(code: "overloaded_error", message: "gone"))])
    let request = ModelRequest(model: "m", system: [ContextSegment(text: "s")], messages: [.user("go")], maxOutputTokens: 256)
    var relay = ReplyStreamRelay()
    var shown: [ReplyStreamEvent] = []

    await #expect(throws: StructuredStreamFailure.self) {
      try await StructuredCall(provider: provider, supportsNativeSchema: false).stream(request, name: "turn", schema: replyAndCountSchema) {
        shown += relay.receive($0)
      }
    }

    #expect(deltas(shown).joined() == "Half a tho")
    #expect(!shown.contains(.reset))
  }

  @Test func shouldReleaseAnUnrestrictedReplyBySentenceAndWithholdFromTheFirstRefusedOne() throws {
    let kept = try #require(ChangeSetElement(source: #"{"op":"b"}"#))
    var relay = ReplyStreamRelay(refuses: fixtureVeto)
    #expect(relay.push(#"{"reply":"One. Tw"#) == [.delta("One.")])
    #expect(relay.push(#"o!\" Three VE"#) == [.delta(" Two!\"")])
    #expect(relay.push(#"TO here. Four."#).isEmpty)
    #expect(relay.push(#" Five.","changeSet":[{"op":"a","name":"VETO"},{"op":"b"}]}"#) == [.change(StreamedChange(index: 0, element: kept))])
    #expect(relay.settle(raw: #"{"reply":"One. Two!\" Three VETO here. Four. Five.","changeSet":[{"op":"a","name":"VETO"},{"op":"b"}]}"#).isEmpty)
    #expect(relay.restart() == [.reset])
    #expect(relay.push(#"{"reply":"Clean"#).isEmpty)
    #expect(relay.settle(raw: #"{"reply":"Clean"}"#) == [.delta("Clean")])
  }

  @Test func shouldNeverShowAnUnrestrictedChangeTooDeeplyNestedToScreen() throws {
    let nested = String(repeating: "[", count: 130) + String(repeating: "]", count: 130)
    let raw = #"{"reply":"Fine.","changeSet":[{"op":"a","x":"# + nested + #"},{"op":"b"}]}"#
    #expect(ChangeSetElement(source: #"{"op":"a","x":"# + nested + "}") != nil)
    var relay = ReplyStreamRelay(refuses: fixtureVeto)
    let shown = relay.push(raw)
    #expect(changeOps(shown) == ["0:b"])
    #expect(relay.settle(raw: raw).isEmpty)

    var standard = ReplyStreamRelay()
    #expect(changeOps(standard.push(raw)) == ["0:a", "1:b"])
  }

  @Test func shouldReleaseAStandardReplyAtOnce() {
    var relay = ReplyStreamRelay(contentMode: .standard)
    #expect(relay.push(#"{"reply":"no sentence end yet"#) == [.delta("no sentence end yet")])
  }

  @Test func shouldScreenAnUnrestrictedReplyAgainstTheHardLineAtTheChatScope() throws {
    let fixture = try HardLineFixture.load()
    let refused = try #require(fixture.find.first { $0.texts.count == 1 && ($0.scope ?? .supplied) == .supplied && $0.rule != nil }?.texts.first)
    let clean = try #require(fixture.find.first { $0.texts.count == 1 && ($0.scope ?? .supplied) == .supplied && $0.rule == nil }?.texts.first)
    let sentence = { (text: String) in OrderedJSON.string(text.jsReplace(builtInPattern("[.!?\\n]", flags: "g"), " ") + ".").jsonText.dropLast() }

    var screened = ReplyStreamRelay(contentMode: .unrestricted)
    #expect(screened.push("{\"reply\":\(sentence(refused))").isEmpty)
    var passed = ReplyStreamRelay(contentMode: .unrestricted)
    #expect(deltas(passed.push("{\"reply\":\(sentence(clean))")).count == 1)
    var standard = ReplyStreamRelay(contentMode: .standard)
    #expect(deltas(standard.push("{\"reply\":\(sentence(refused))")).count == 1)
  }

  @Test func shouldVoidWhatWasShownWhenTheOutputScreenRefusesTheAnswer() {
    var relay = ReplyStreamRelay(refuses: fixtureVeto)
    _ = relay.push(#"{"reply":"Fine. Still fine"}"#)
    #expect(relay.restart() == [.reset])
    #expect(relay.settle(raw: #"{"reply":"Fine. Still fine"}"#).isEmpty)
  }

  @Test func shouldShowALoneSurrogateEscapeAsTheReplacementCharacter() {
    var relay = ReplyStreamRelay()
    #expect(deltas(relay.push(#"{"reply":"a\ud800b\udc00"}"#)).joined() == "a\u{FFFD}b\u{FFFD}")
    #expect(relay.settle(raw: #"{"reply":"a\ud800b\udc00"}"#).isEmpty)
  }

  @Test func shouldReleaseALongUnpunctuatedReplyWithoutRescanningWhatItHolds() {
    var relay = ReplyStreamRelay(refuses: fixtureVeto)
    _ = relay.push(#"{"reply":""#)
    for _ in 0..<20_000 { #expect(relay.push("w").isEmpty) }
    #expect(relay.settle(raw: "{\"reply\":\"" + String(repeating: "w", count: 20_000) + "\"}") == [.delta(String(repeating: "w", count: 20_000))])
  }
}
