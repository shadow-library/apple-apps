import Foundation
import ShadowCore
import ShadowNetworking
import ShadowTestSupport
import Testing

@testable import ShadowAI

private func errorBody(type: String, message: String) -> String {
  #"{"type": "error", "error": {"type": "\#(type)", "message": "\#(message)"}, "request_id": "req_011CSHoEeqs5C35K2UUqR7Fy"}"#
}

@Suite("AnthropicProvider failures", .timeLimit(.minutes(1)))
struct AnthropicFailureTests {
  private static let startThenError = #"""
    event: message_start
    data: {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}

    event: ping
    data: {"type": "ping"}

    event: error
    data: {"type": "error", "error": {"type": "%@", "message": "%@"}}


    """#

  private static let textThenError = #"""
    event: message_start
    data: {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}

    event: content_block_start
    data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

    event: content_block_delta
    data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Once upon"}}

    event: error
    data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}


    """#

  private static func errorEvent(after transcript: String, type: String, message: String) -> String {
    transcript.replacingOccurrences(of: #""type": "%@", "message": "%@""#, with: #""type": "\#(type)", "message": "\#(message)""#)
  }

  private static func run(_ transport: AnthropicTestTransport, trustedClock: TrustedClock? = nil) async throws -> (events: [ModelEvent], error: ModelError?) {
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential(), trustedClock: trustedClock)
    return await AnthropicFixtures.drain(provider.stream(AnthropicFixtures.request))
  }

  @Test(
    "should surface an overload or rate limit sent before any text as retryable",
    arguments: [
      ("overloaded_error", "Overloaded", ModelError.overloaded(retryAfter: nil)), ("rate_limit_error", "Rate limited", .rateLimited(retryAfter: nil)),
      ("api_error", "Internal server error", .server(status: 500)),
    ]
  )
  func surfacesErrorBeforeText(type: String, message: String, expected: ModelError) async throws {
    let outcome = try await Self.run(AnthropicTestTransport(transcript: Self.errorEvent(after: Self.startThenError, type: type, message: message)))

    #expect(outcome.events == [.started(requestID: "req_1", generationID: "msg_1")])
    #expect(outcome.error == expected)
    #expect(outcome.error?.isRetryable == true)
  }

  @Test("should surface any other error sent before text as a mid-stream error")
  func surfacesOtherErrorBeforeText() async throws {
    let outcome = try await Self.run(AnthropicTestTransport(transcript: Self.errorEvent(after: Self.startThenError, type: "invalid_request_error", message: "Bad")))

    #expect(outcome.error == .midStream(code: "invalid_request_error", message: "Bad"))
  }

  @Test("should surface an error sent after text as a mid-stream error")
  func surfacesErrorAfterText() async throws {
    let outcome = try await Self.run(AnthropicTestTransport(transcript: Self.textThenError))

    #expect(outcome.events == [.started(requestID: "req_1", generationID: "msg_1"), .textDelta("Once upon")])
    #expect(outcome.error == .midStream(code: "overloaded_error", message: "Overloaded"))
    #expect(outcome.error?.isRetryable == false)
  }

  @Test("should fail as malformed when an error event cannot be read")
  func failsOnUnreadableErrorEvent() async throws {
    let outcome = try await Self.run(AnthropicTestTransport(transcript: "event: error\ndata: {\"type\": \"error\"}\n\n"))

    #expect(outcome.error == .malformedResponse("The provider sent an unreadable error event."))
  }

  @Test("should retry an overload sent before text and then succeed, reporting the failed attempt's ids")
  func retriesOverloadThenSucceeds() async throws {
    let calls = RunCounter()
    let overloaded = Self.errorEvent(after: Self.startThenError, type: "overloaded_error", message: "Overloaded")
    let transport = AnthropicTestTransport(
      streaming: StubHTTPStreamingTransport { request in
        calls.increment()
        let call = calls.value
        return try StubHTTPStreamingTransport.response(to: request, headers: ["request-id": "req_\(call)"], steps: [.text(call == 1 ? overloaded : AnthropicFixtures.reply)])
      }
    )
    let base = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential())
    let clock = ManualClock(.advancesOnSleep)
    let retrying = RetryingProvider(base, policy: RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1), maxDelay: .seconds(60), jitter: 0), clock: clock, random: { 0 })

    let outcome = await AnthropicFixtures.drain(retrying.stream(AnthropicFixtures.request))

    #expect(outcome.error == nil)
    #expect(
      outcome.events == [
        .retrying(attempt: 1, delay: .seconds(1), cause: .overloaded(retryAfter: nil), requestID: "req_1", generationID: "msg_1"),
        .started(requestID: "req_2", generationID: "msg_1"), .textDelta("Hello"), .finished(usage: TokenUsage(input: 25, output: 15), reportedCost: nil, stop: .endTurn),
      ]
    )
    #expect(clock.requestedSleeps == [.seconds(1)])
    #expect(transport.requests.count == 2)
  }

  @Test(
    "should map each documented error status and type",
    arguments: [
      (400, "invalid_request_error", "messages: roles must alternate", ModelError.invalidRequest("messages: roles must alternate")),
      (401, "authentication_error", "invalid x-api-key", .authentication),
      (402, "billing_error", "Your credit balance is too low", .insufficientCredits),
      (403, "permission_error", "Not allowed", .forbidden("Not allowed")),
      (404, "not_found_error", "model: claude-nope", .invalidRequest("model: claude-nope")),
      (409, "conflict_error", "Conflict", .invalidRequest("Conflict")),
      (413, "request_too_large", "Request exceeds the maximum size", .invalidRequest("Request exceeds the maximum size")),
      (429, "rate_limit_error", "Rate limited", .rateLimited(retryAfter: nil)),
      (500, "api_error", "Internal server error", .server(status: 500)),
      (504, "timeout_error", "Timed out", .server(status: 504)),
      (529, "overloaded_error", "Overloaded", .overloaded(retryAfter: nil)),
    ]
  )
  func mapsErrorStatus(status: Int, type: String, message: String, expected: ModelError) async throws {
    let transport = AnthropicTestTransport(status: status, headers: ["request-id": "req_1"], transcript: errorBody(type: type, message: message))

    let outcome = try await Self.run(transport)

    #expect(outcome.events.isEmpty)
    #expect(outcome.error == expected)
  }

  @Test(
    "should fall back to the status when the error body is unknown or unreadable",
    arguments: [
      (418, errorBody(type: "teapot_error", message: "short and stout"), ModelError.invalidRequest("The provider responded with status 418.")),
      (502, "<html>Bad gateway</html>", .server(status: 502)),
      (503, "", .overloaded(retryAfter: nil)),
      (302, "", .malformedResponse("The provider responded with unexpected status 302.")),
    ]
  )
  func fallsBackToStatus(status: Int, body: String, expected: ModelError) async throws {
    let outcome = try await Self.run(AnthropicTestTransport(status: status, transcript: body))

    #expect(outcome.error == expected)
  }

  @Test("should truncate the provider's message to 300 characters")
  func truncatesMessage() async throws {
    let message = String(repeating: "x", count: 1_000)

    let outcome = try await Self.run(AnthropicTestTransport(status: 400, transcript: errorBody(type: "invalid_request_error", message: message)))

    #expect(outcome.error == .invalidRequest(String(repeating: "x", count: 300)))
  }

  @Test(
    "should honour retry-after on a rate limit or overload",
    arguments: [(429, "rate_limit_error", ModelError.rateLimited(retryAfter: .seconds(30))), (529, "overloaded_error", .overloaded(retryAfter: .seconds(30)))]
  )
  func honoursRetryAfter(status: Int, type: String, expected: ModelError) async throws {
    let transport = AnthropicTestTransport(status: status, headers: ["Retry-After": "30"], transcript: errorBody(type: type, message: "Slow down"))

    let outcome = try await Self.run(transport)

    #expect(outcome.error == expected)
  }

  @Test("should feed the Date header of a streamed reply and of an error response to the trusted clock", arguments: [200, 529])
  func feedsTrustedClock(status: Int) async throws {
    let clock = TrustedClock(monotonic: AnthropicFrozenTime())
    let body = status == 200 ? AnthropicFixtures.reply : errorBody(type: "overloaded_error", message: "Overloaded")
    let transport = AnthropicTestTransport(status: status, headers: ["request-id": "req_1", "Date": "Tue, 10 Nov 2026 12:00:00 GMT"], transcript: body)

    _ = try await Self.run(transport, trustedClock: clock)

    #expect(clock.now() == .estimate(Date(timeIntervalSince1970: 1_794_312_000)))
  }

  @Test("should do no work until the stream is iterated")
  func isLazy() async throws {
    let transport = AnthropicTestTransport(transcript: AnthropicFixtures.reply)
    let credentialCalls = RunCounter()
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential(), credentialCalls: credentialCalls)

    let stream = provider.stream(AnthropicFixtures.request)

    #expect(transport.requests.isEmpty)
    #expect(credentialCalls.value == 0)
    let outcome = await AnthropicFixtures.drain(stream)
    #expect(outcome.events == AnthropicFixtures.replyEvents)
    #expect(transport.requests.count == 1)
    #expect(credentialCalls.value == 1)
  }

  @Test("should stop reading the body and end with cancelled when the consumer is cancelled")
  func cancelsMidStream() async throws {
    let prefix = try #require(AnthropicFixtures.reply.components(separatedBy: "event: content_block_stop").first)
    let bodyEnded = Signal()
    let transport = AnthropicTestTransport(
      streaming: StubHTTPStreamingTransport { request in
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.onTermination = { _ in bodyEnded.fire() }
        continuation.yield(Data(prefix.utf8))
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["request-id": "req_1"]) else {
          throw URLError(.badURL)
        }
        return HTTPStreamingResponse(response: response, body: body)
      }
    )
    let stream = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential()).stream(AnthropicFixtures.request)
    let firstText = Signal()

    let consumer = Task { () -> (events: [ModelEvent], error: ModelError?) in
      var events: [ModelEvent] = []
      do throws(ModelError) {
        for try await event in stream {
          events.append(event)
          if case .textDelta = event { firstText.fire() }
        }
        return (events, nil)
      } catch {
        return (events, error)
      }
    }
    await firstText.wait()
    consumer.cancel()
    let outcome = await consumer.value

    #expect(outcome.events == Array(AnthropicFixtures.replyEvents.prefix(2)))
    #expect(outcome.error == .cancelled)
    await bodyEnded.wait()
  }
}
