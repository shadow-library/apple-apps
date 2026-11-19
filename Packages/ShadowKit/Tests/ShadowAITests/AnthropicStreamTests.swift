import Foundation
import ShadowCore
import ShadowNetworking
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("AnthropicProvider streams", TestTimeLimit.quick)
struct AnthropicStreamTests {
  private static func run(_ transcript: String, headers: [String: String] = ["request-id": "req_1"]) async throws -> (events: [ModelEvent], error: ModelError?) {
    let transport = StubHTTPExchangeTransport(headers: headers, transcript: transcript)
    return await AnthropicFixtures.drain(AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential()).stream(AnthropicFixtures.request))
  }

  private static func ending(_ stopDelta: String) -> String {
    #"""
    event: message_start
    data: {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 10, "output_tokens": 1}}}

    event: content_block_start
    data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

    event: content_block_delta
    data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Partial"}}

    event: content_block_stop
    data: {"type": "content_block_stop", "index": 0}

    event: message_delta
    data: {"type": "message_delta", "delta": \#(stopDelta), "usage": {"output_tokens": 7}}

    event: message_stop
    data: {"type": "message_stop"}


    """#
  }

  @Test("should report started, text and a finish with input, output and cache token counts")
  func streamsPlainSuccess() async throws {
    let transcript = #"""
      event: message_start
      data: {"type": "message_start", "message": {"id": "msg_01XFDUDYJgAACzvnptvVoYEL", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "cache_creation_input_tokens": 2051, "cache_read_input_tokens": 4096, "cache_creation": {"ephemeral_5m_input_tokens": 2000, "ephemeral_1h_input_tokens": 51}, "output_tokens": 1}}}

      event: content_block_start
      data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

      event: ping
      data: {"type": "ping"}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "!"}}

      event: content_block_stop
      data: {"type": "content_block_stop", "index": 0}

      event: message_delta
      data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}, "usage": {"output_tokens": 15}}

      event: message_stop
      data: {"type": "message_stop"}


      """#

    let outcome = try await Self.run(transcript, headers: ["request-id": "req_018EeWyXxfu5pfWkrYcMdjWG"])

    #expect(outcome.error == nil)
    #expect(
      outcome.events == [
        .started(requestID: "req_018EeWyXxfu5pfWkrYcMdjWG", generationID: "msg_01XFDUDYJgAACzvnptvVoYEL"), .textDelta("Hello"), .textDelta("!"),
        .finished(usage: TokenUsage(input: 25, output: 15, cacheRead: 4096, cacheWriteShort: 2000, cacheWriteLong: 51), reportedCost: nil, stop: .endTurn),
      ]
    )
  }

  @Test("should take the cumulative counts of the last message_delta over those of message_start")
  func takesCumulativeUsage() async throws {
    let transcript = #"""
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":2679,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":10682,"cache_creation_input_tokens":300,"cache_read_input_tokens":512,"output_tokens":510,"server_tool_use":{"web_search_requests":1}}}

      event: message_stop
      data: {"type":"message_stop"}


      """#

    let outcome = try await Self.run(transcript)

    let usage = TokenUsage(input: 10_682, output: 510, cacheRead: 512, cacheWriteShort: 300, cacheWriteLong: 0)
    #expect(outcome.events.last == .finished(usage: usage, reportedCost: nil, stop: .endTurn))
  }

  @Test("should reassemble text split across many deltas and arbitrary chunk boundaries", arguments: [1, 3, 7, 64])
  func reassemblesChunks(chunkSize: Int) async throws {
    let pieces = ["Mara ", "opened", " the door", "—", "and the 🌊 ", "came in.\n", "Ünïcödé"]
    var transcript = #"""
      event: message_start
      data: {"type": "message_start", "message": {"id": "msg_3", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 5, "output_tokens": 1}}}

      event: content_block_start
      data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}


      """#
    for piece in pieces {
      let escaped = piece.replacingOccurrences(of: "\n", with: #"\n"#)
      transcript += "event: content_block_delta\r\ndata: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"text_delta\", \"text\": \"\(escaped)\"}}\r\n\r\n"
    }
    transcript += #"""
      event: content_block_stop
      data: {"type": "content_block_stop", "index": 0}

      event: message_delta
      data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}, "usage": {"output_tokens": 40}}

      event: message_stop
      data: {"type": "message_stop"}


      """#
    let bytes = Array(transcript.utf8)
    let steps = stride(from: 0, to: bytes.count, by: chunkSize).map { StubHTTPStreamingTransport.Step.chunk(Data(bytes[$0..<min($0 + chunkSize, bytes.count)])) }
    let transport = StubHTTPExchangeTransport(streaming: StubHTTPStreamingTransport(headers: ["request-id": "req_1"], steps: steps))

    let outcome = await AnthropicFixtures.drain(AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential()).stream(AnthropicFixtures.request))

    #expect(outcome.error == nil)
    #expect(outcome.events.compactMap { if case .textDelta(let text) = $0 { text } else { nil } } == pieces)
  }

  @Test("should ignore summarized thinking, signatures and redacted thinking without producing text or an error")
  func ignoresThinking() async throws {
    let transcript = #"""
      event: message_start
      data: {"type": "message_start", "message": {"id": "msg_4", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 9, "output_tokens": 1}}}

      event: content_block_start
      data: {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": ""}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "I need to find the GCD of 1071 and 462."}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."}}

      event: content_block_stop
      data: {"type": "content_block_stop", "index": 0}

      event: content_block_start
      data: {"type": "content_block_start", "index": 1, "content_block": {"type": "redacted_thinking", "data": "EmwKAhgBEgy3va3pzix/LafPsn4aDFIT2Xlxh0L5L8rLVyIwxtE3rAFBa8cr3qpP"}}

      event: content_block_stop
      data: {"type": "content_block_stop", "index": 1}

      event: content_block_start
      data: {"type": "content_block_start", "index": 2, "content_block": {"type": "text", "text": ""}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 2, "delta": {"type": "text_delta", "text": "The GCD is 21."}}

      event: content_block_stop
      data: {"type": "content_block_stop", "index": 2}

      event: message_delta
      data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}, "usage": {"output_tokens": 120}}

      event: message_stop
      data: {"type": "message_stop"}


      """#

    let outcome = try await Self.run(transcript)

    #expect(outcome.error == nil)
    #expect(
      outcome.events == [
        .started(requestID: "req_1", generationID: "msg_4"), .textDelta("The GCD is 21."), .finished(usage: TokenUsage(input: 9, output: 120), reportedCost: nil, stop: .endTurn),
      ]
    )
  }

  @Test("should ignore pings, unknown events, unknown content blocks and unknown deltas")
  func ignoresUnknownEvents() async throws {
    let transcript = #"""
      event: ping
      data: {"type": "ping"}

      event: message_start
      data: {"type": "message_start", "message": {"id": "msg_5", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 3, "output_tokens": 1}, "future_field": {"x": 1}}}

      event: future_event
      data: not even json

      event: content_block_start
      data: {"type": "content_block_start", "index": 0, "content_block": {"type": "future_block", "payload": [1, 2]}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 0, "delta": {"type": "future_delta", "value": 1}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "{\"location\": \"San Fra"}}

      event: content_block_stop
      data: {"type": "content_block_stop", "index": 0}

      event: ping
      data: {"type": "ping"}

      data: {"type": "another_future_event"}

      : a comment line

      event: content_block_start
      data: {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": ""}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 1, "delta": {"type": "citations_delta", "citation": {"type": "char_location"}}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Still here"}}

      event: content_block_stop
      data: {"type": "content_block_stop", "index": 1}

      event: message_delta
      data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}, "usage": {"output_tokens": 4}}

      event: message_stop
      data: {"type": "message_stop"}


      """#

    let outcome = try await Self.run(transcript)

    #expect(outcome.error == nil)
    #expect(
      outcome.events == [
        .started(requestID: "req_1", generationID: "msg_5"), .textDelta("Still here"), .finished(usage: TokenUsage(input: 3, output: 4), reportedCost: nil, stop: .endTurn),
      ]
    )
  }

  @Test("should finish with a refusal carrying the category from stop_details")
  func reportsRefusal() async throws {
    let outcome = try await Self.run(
      Self.ending(#"{"stop_reason": "refusal", "stop_sequence": null, "stop_details": {"type": "refusal", "category": "cyber", "explanation": "Declined."}}"#)
    )

    #expect(outcome.error == nil)
    #expect(outcome.events.last == .finished(usage: TokenUsage(input: 10, output: 7), reportedCost: nil, stop: .refusal(category: "cyber")))
  }

  @Test("should finish with a refusal without a category when stop_details names none")
  func reportsRefusalWithoutCategory() async throws {
    let outcome = try await Self.run(Self.ending(#"{"stop_reason": "refusal", "stop_sequence": null, "stop_details": {"type": "refusal", "category": null, "explanation": null}}"#))

    #expect(outcome.events.last == .finished(usage: TokenUsage(input: 10, output: 7), reportedCost: nil, stop: .refusal(category: nil)))
  }

  @Test("should finish with max tokens when the output or the context window was cut", arguments: ["max_tokens", "model_context_window_exceeded"])
  func reportsMaxTokens(reason: String) async throws {
    let outcome = try await Self.run(Self.ending(#"{"stop_reason": "\#(reason)", "stop_sequence": null}"#))

    #expect(outcome.events.last == .finished(usage: TokenUsage(input: 10, output: 7), reportedCost: nil, stop: .maxTokens))
  }

  @Test("should keep a stop reason it has no case for as other", arguments: ["pause_turn", "tool_use", "stop_sequence", "a_reason_from_the_future"])
  func keepsUnknownStopReason(reason: String) async throws {
    let outcome = try await Self.run(Self.ending(#"{"stop_reason": "\#(reason)", "stop_sequence": null}"#))

    #expect(outcome.events.last == .finished(usage: TokenUsage(input: 10, output: 7), reportedCost: nil, stop: .other(reason)))
  }

  @Test("should fail as malformed when the body ends before message_stop", arguments: ["message_delta", "content_block_delta", "message_start"])
  func failsOnEarlyEnd(lastEvent: String) async throws {
    let full = Self.ending(#"{"stop_reason": "end_turn", "stop_sequence": null}"#)
    let last = try #require(full.range(of: "event: \(lastEvent)\n"))
    let truncated = String(full[..<(try #require(full.range(of: "\n\n", range: last.upperBound..<full.endIndex))).upperBound])

    let outcome = try await Self.run(truncated)

    #expect(outcome.error == .malformedResponse("The reply ended before it finished."))
    #expect(!outcome.events.contains { if case .finished = $0 { true } else { false } })
  }

  @Test("should fail as malformed without quoting a payload that is not JSON")
  func failsOnMalformedJSON() async throws {
    let transcript = #"""
      event: message_start
      data: {"type": "message_start", "message": {"id": "msg_6", "usage": {"input_tokens": 1, "output_tokens": 1}}}

      event: content_block_delta
      data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "secret-payload-SHOULD-NOT-LEAK"

      event: message_stop
      data: {"type": "message_stop"}


      """#

    let outcome = try await Self.run(transcript)

    guard case .malformedResponse(let message) = outcome.error else {
      Issue.record("Expected malformedResponse, got \(String(describing: outcome.error))")
      return
    }
    #expect(!message.contains("SHOULD-NOT-LEAK"))
    #expect(outcome.events == [.started(requestID: "req_1", generationID: "msg_6")])
  }

  @Test("should fail as malformed when content arrives before message_start")
  func failsOnContentBeforeStart() async throws {
    let transcript = #"""
      event: content_block_delta
      data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "early"}}


      """#

    let outcome = try await Self.run(transcript)

    #expect(outcome.error == .malformedResponse("The provider sent content before starting the reply."))
    #expect(outcome.events.isEmpty)
  }

  @Test("should fail as malformed when the reply starts twice")
  func failsOnSecondStart() async throws {
    let start = #"""
      event: message_start
      data: {"type": "message_start", "message": {"id": "msg_7", "usage": {"input_tokens": 1, "output_tokens": 1}}}


      """#

    let outcome = try await Self.run(start + start)

    #expect(outcome.error == .malformedResponse("The provider started the reply twice."))
  }

  @Test("should fail as malformed when message_stop arrives without a stop reason")
  func failsWithoutStopReason() async throws {
    let transcript = #"""
      event: message_start
      data: {"type": "message_start", "message": {"id": "msg_8", "usage": {"input_tokens": 1, "output_tokens": 1}}}

      event: message_stop
      data: {"type": "message_stop"}


      """#

    let outcome = try await Self.run(transcript)

    #expect(outcome.error == .malformedResponse("The reply finished without a stop reason."))
  }

  @Test("should stop reading after message_stop")
  func stopsAfterMessageStop() async throws {
    let outcome = try await Self.run(AnthropicFixtures.reply + "event: message_start\ndata: broken\n\n")

    #expect(outcome.error == nil)
    #expect(outcome.events == AnthropicFixtures.replyEvents)
  }

  @Test("should map a transport failure in the middle of the body")
  func mapsBodyTransportFailure() async throws {
    let prefix = try #require(AnthropicFixtures.reply.components(separatedBy: "event: content_block_stop").first)
    let transport = StubHTTPExchangeTransport(
      streaming: StubHTTPStreamingTransport(headers: ["request-id": "req_1"], steps: [.text(prefix), .failure(URLError(.networkConnectionLost))])
    )

    let outcome = await AnthropicFixtures.drain(AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential()).stream(AnthropicFixtures.request))

    #expect(outcome.events == Array(AnthropicFixtures.replyEvents.prefix(2)))
    #expect(outcome.error == .transport(.networkConnectionLost))
  }

  @Test("should map a transport failure before any response")
  func mapsConnectionFailure() async throws {
    let transport = StubHTTPExchangeTransport(streaming: StubHTTPStreamingTransport { _ in throw URLError(.notConnectedToInternet) })

    let outcome = await AnthropicFixtures.drain(AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential()).stream(AnthropicFixtures.request))

    #expect(outcome.events.isEmpty)
    #expect(outcome.error == .transport(.notConnectedToInternet))
  }

  private static func usageTranscript(start: String?, delta: String?) -> String {
    let startUsage = start.map { #", "usage": \#($0)"# } ?? ""
    let deltaUsage = delta.map { #", "usage": \#($0)"# } ?? ""
    return #"""
      event: message_start
      data: {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5"\#(startUsage)}}

      event: message_delta
      data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}\#(deltaUsage)}

      event: message_stop
      data: {"type": "message_stop"}


      """#
  }

  @Test(
    "should clamp negative token counts to zero",
    arguments: [
      (#"{"input_tokens": -4, "output_tokens": -9, "cache_read_input_tokens": -1, "cache_creation_input_tokens": -2}"#, TokenUsage(input: 0, output: 0)),
      (#"{"input_tokens": 3, "output_tokens": -9, "cache_creation": {"ephemeral_5m_input_tokens": -7, "ephemeral_1h_input_tokens": -8}}"#, TokenUsage(input: 3, output: 0)),
    ]
  )
  func clampsNegativeCounts(usage: String, expected: TokenUsage) async throws {
    let outcome = try await Self.run(Self.usageTranscript(start: usage, delta: nil))

    #expect(outcome.error == nil)
    #expect(outcome.events.last == .finished(usage: expected, reportedCost: nil, stop: .endTurn))
  }

  @Test("should carry a count of the largest representable size")
  func carriesLargestCount() async throws {
    let outcome = try await Self.run(Self.usageTranscript(start: #"{"input_tokens": 9223372036854775807, "output_tokens": 1}"#, delta: nil))

    #expect(outcome.error == nil)
    #expect(outcome.events.last == .finished(usage: TokenUsage(input: Int.max, output: 1), reportedCost: nil, stop: .endTurn))
  }

  @Test("should fail as malformed on a count beyond 64 bits instead of wrapping it", arguments: ["input_tokens", "output_tokens", "cache_read_input_tokens"])
  func refusesEnormousCount(field: String) async throws {
    let outcome = try await Self.run(Self.usageTranscript(start: #"{"\#(field)": 99999999999999999999}"#, delta: nil))

    #expect(outcome.events.isEmpty)
    #expect(outcome.error == .malformedResponse("The provider sent an unreadable message_start event."))
  }

  @Test("should fail as malformed on an enormous count in the closing delta")
  func refusesEnormousClosingCount() async throws {
    let outcome = try await Self.run(Self.usageTranscript(start: #"{"input_tokens": 5, "output_tokens": 1}"#, delta: #"{"output_tokens": 99999999999999999999}"#))

    #expect(outcome.events == [.started(requestID: "req_1", generationID: "msg_1")])
    #expect(outcome.error == .malformedResponse("The provider sent an unreadable message_delta event."))
  }

  @Test(
    "should report zero for counts the provider never sent",
    arguments: [
      (String?.none, String?.none, TokenUsage(input: 0, output: 0)), (nil, #"{"output_tokens": 6}"#, TokenUsage(input: 0, output: 6)),
      (#"{"input_tokens": 8}"#, nil, TokenUsage(input: 8, output: 0)), (#"{}"#, #"{}"#, TokenUsage(input: 0, output: 0)),
    ]
  )
  func defaultsMissingCounts(start: String?, delta: String?, expected: TokenUsage) async throws {
    let outcome = try await Self.run(Self.usageTranscript(start: start, delta: delta))

    #expect(outcome.error == nil)
    #expect(outcome.events.last == .finished(usage: expected, reportedCost: nil, stop: .endTurn))
  }
}
