import Foundation
import ShadowCore
import ShadowNetworking
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowAI

@Suite("OpenRouterProvider streams", .timeLimit(.minutes(1)))
struct OpenRouterStreamTests {
  private typealias F = OpenRouterFixtures

  private static let usage = """
    {"prompt_tokens":1200,"completion_tokens":40,"total_tokens":1240,"prompt_tokens_details":{"cached_tokens":1000,"cache_write_tokens":100,"audio_tokens":0},\
    "completion_tokens_details":{"reasoning_tokens":12},"cost":0.000123456789,"is_byok":false,\
    "cost_details":{"upstream_inference_cost":null,"upstream_inference_prompt_cost":0.0001,"upstream_inference_completions_cost":0.00002}}
    """
  private static let expectedUsage = TokenUsage(input: 100, output: 40, cacheRead: 1000, cacheWriteShort: 100)

  private static func run(_ transport: OpenRouterTestTransport, trustedClock: TrustedClock? = nil) async throws -> (events: [ModelEvent], error: ModelError?) {
    await F.drain(try F.provider(transport, trustedClock: trustedClock).stream(F.request))
  }

  private static func run(status: Int = 200, headers: [String: String] = [:], _ sse: String) async throws -> (events: [ModelEvent], error: ModelError?) {
    try await run(OpenRouterTestTransport(status: status, headers: headers, sse: sse))
  }

  @Test("should deliver text, then usage and cost from the last chunk, across keep-alive comments")
  func deliversSuccess() async throws {
    let sse = F.sse(
      ": OPENROUTER PROCESSING", F.chunk("Hel"), ": OPENROUTER PROCESSING", F.chunk("lo", finish: "stop", native: "end_turn"),
      F.usageChunk(Self.usage), "[DONE]"
    )

    let outcome = try await Self.run(sse)

    #expect(outcome.error == nil)
    #expect(
      outcome.events == [
        .started(requestID: nil, generationID: "gen-1"), .textDelta("Hel"), .textDelta("lo"),
        .finished(usage: Self.expectedUsage, reportedCost: Cost(nanoUSD: 123_457), stop: .endTurn),
      ]
    )
  }

  @Test("should reassemble events split at arbitrary byte boundaries, inside a multi-byte character too")
  func reassemblesSplitBytes() async throws {
    let sse = F.sse(F.chunk("Café ☕️"), F.chunk(" done", finish: "stop"), F.usageChunk(Self.usage), "[DONE]")
    let bytes = Array(sse.utf8)
    let steps = stride(from: 0, to: bytes.count, by: 7).map { StubHTTPStreamingTransport.Step.chunk(Data(bytes[$0..<min($0 + 7, bytes.count)])) }
    let transport = OpenRouterTestTransport(streaming: StubHTTPStreamingTransport(steps: steps))

    let outcome = try await Self.run(transport)

    #expect(outcome.error == nil)
    #expect(outcome.events.dropFirst().dropLast() == [.textDelta("Café ☕️"), .textDelta(" done")])
    #expect(outcome.events.last == .finished(usage: Self.expectedUsage, reportedCost: Cost(nanoUSD: 123_457), stop: .endTurn))
  }

  @Test("should accept CRLF line endings and a final event without its blank line")
  func acceptsCRLFAndUnterminatedSentinel() async throws {
    let sse = "data: \(F.chunk("Hi", finish: "stop"))\r\n\r\n: OPENROUTER PROCESSING\r\n\r\ndata: [DONE]"

    let outcome = try await Self.run(sse)

    #expect(outcome.error == nil)
    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-1"), .textDelta("Hi"), .finished(usage: .zero, reportedCost: nil, stop: .endTurn)])
  }

  @Test("should ignore reasoning content and unknown members")
  func ignoresReasoning() async throws {
    let reasoning = """
      {"id":"gen-1","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"Let me think","reasoning_details":[{"type":"reasoning.text","text":"Let me think"}]},\
      "finish_reason":null,"logprobs":null}],"openrouter_metadata":{"strategy":"direct"},"surprise":[1,2.5,{"x":null}]}
      """
    let sse = F.sse(reasoning, F.chunk("Answer", finish: "stop"), "[DONE]")

    let outcome = try await Self.run(sse)

    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-1"), .textDelta("Answer"), .finished(usage: .zero, reportedCost: nil, stop: .endTurn)])
  }

  @Test(
    "should map each finish reason onto a stop reason",
    arguments: [
      ("stop", nil, StopReason.endTurn), ("length", nil, .maxTokens), ("content_filter", nil, .contentFilter), ("content_filter", "refusal", .refusal(category: nil)),
      ("tool_calls", nil, .other("tool_calls")), ("brand_new_reason", nil, .other("brand_new_reason")),
    ]
  )
  func mapsFinishReasons(finish: String, native: String?, stop: StopReason) async throws {
    let outcome = try await Self.run(F.sse(F.chunk("x", finish: finish, native: native), "[DONE]"))

    #expect(outcome.error == nil)
    #expect(outcome.events.last == .finished(usage: .zero, reportedCost: nil, stop: stop))
  }

  @Test("should report a refusal carried in the delta as a refusal, without passing its text on as reply")
  func mapsRefusalDelta() async throws {
    let refusal = """
      {"id":"gen-1","choices":[{"index":0,"delta":{"role":"assistant","content":null,"refusal":"I can't help with that."},"finish_reason":"content_filter"}]}
      """

    let outcome = try await Self.run(F.sse(refusal, "[DONE]"))

    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-1"), .finished(usage: .zero, reportedCost: nil, stop: .refusal(category: nil))])
  }

  @Test(
    "should surface an error chunk before any text as the specific error it is",
    arguments: [
      (429, "rate_limit_exceeded", ModelError.rateLimited(retryAfter: nil)), (503, "provider_overloaded", .overloaded(retryAfter: nil)),
      (402, "payment_required", .insufficientCredits), (502, "provider_unavailable", .server(status: 502)), (401, "authentication", .authentication),
      (400, "context_length_exceeded", .invalidRequest("Prompt is too long")),
    ]
  )
  func mapsErrorBeforeText(code: Int, type: String, expected: ModelError) async throws {
    let outcome = try await Self.run(F.sse(": OPENROUTER PROCESSING", F.errorChunk(code: code, message: "Prompt is too long", type: type, id: "gen-err")))

    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-err")])
    #expect(outcome.error == expected)
  }

  @Test("should report an error chunk after text as a mid-stream failure")
  func mapsErrorAfterText() async throws {
    let sse = F.sse(F.chunk("Partial"), F.errorChunk(code: 502, message: "Provider disconnected unexpectedly", type: "provider_unavailable"))

    let outcome = try await Self.run(sse)

    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-1"), .textDelta("Partial")])
    #expect(outcome.error == .midStream(code: "provider_unavailable", message: "Provider disconnected unexpectedly"))
  }

  @Test("should treat an overload after text as mid-stream, never retryable")
  func overloadAfterTextIsMidStream() async throws {
    let sse = F.sse(F.chunk("Partial"), F.errorChunk(code: 503, message: "Overloaded", type: "provider_overloaded"))

    let outcome = try await Self.run(sse)

    #expect(outcome.error == .midStream(code: "provider_overloaded", message: "Overloaded"))
    #expect(outcome.error?.isRetryable == false)
  }

  @Test("should read an error frame of the reference gateway's shape, with the routed provider's reason")
  func readsRoutedReason() async throws {
    let frame = """
      {"error":{"message":"Provider returned error","code":400,"metadata":{"provider_name":"Anthropic","raw":"{\\"type\\":\\"error\\",\\"error\\":{\\"message\\":\\"temperature is not allowed\\"}}"}}}
      """

    let outcome = try await Self.run(F.sse(frame))

    #expect(outcome.error == .invalidRequest("Provider returned error (Anthropic: temperature is not allowed)"))
  }

  @Test("should end with a malformed response when the body ends before a finish reason or the sentinel")
  func failsTruncatedBody() async throws {
    let outcome = try await Self.run(F.sse(F.chunk("Once upon")))

    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-1"), .textDelta("Once upon")])
    #expect(outcome.error == .malformedResponse("The reply ended before it finished."))
  }

  @Test("should finish a reply whose body ends after its finish reason without the sentinel")
  func acceptsFinishWithoutSentinel() async throws {
    let outcome = try await Self.run(F.sse(F.chunk("Done", finish: "stop")))

    #expect(outcome.error == nil)
    #expect(outcome.events.last == .finished(usage: .zero, reportedCost: nil, stop: .endTurn))
  }

  @Test("should fail an empty body as malformed")
  func failsEmptyBody() async throws {
    let outcome = try await Self.run("")

    #expect(outcome.events.isEmpty)
    #expect(outcome.error == .malformedResponse("The reply ended before it finished."))
  }

  @Test("should not let a reply grow after its finish reason")
  func ignoresContentAfterFinish() async throws {
    let late = #"{"id":"gen-1","choices":[{"index":0,"delta":{"content":" and more","refusal":"no"},"finish_reason":"length"}]}"#

    let outcome = try await Self.run(F.sse(F.chunk("Done", finish: "stop"), late, F.usageChunk(Self.usage), "[DONE]"))

    #expect(outcome.error == nil)
    #expect(
      outcome.events == [
        .started(requestID: nil, generationID: "gen-1"), .textDelta("Done"),
        .finished(usage: Self.expectedUsage, reportedCost: Cost(nanoUSD: 123_457), stop: .endTurn),
      ]
    )
  }

  @Test("should finish at the sentinel and ignore anything after it")
  func stopsAtSentinel() async throws {
    let outcome = try await Self.run(F.sse(F.chunk("a", finish: "stop"), "[DONE]", F.chunk("late"), "{broken"))

    #expect(outcome.error == nil)
    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-1"), .textDelta("a"), .finished(usage: .zero, reportedCost: nil, stop: .endTurn)])
  }

  @Test(
    "should fail a chunk that is not JSON, or not a chat-completion chunk",
    arguments: ["{not json", "[1,2]", "\"text\"", #"{"choices":"many"}"#, #"{"choices":[{"delta":{"content":7}}]}"#]
  )
  func failsMalformedChunk(data: String) async throws {
    let outcome = try await Self.run(F.sse(F.chunk("ok"), data))

    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-1"), .textDelta("ok")])
    #expect(outcome.error == .malformedResponse("The provider sent a stream chunk that is not a chat-completion chunk."))
  }

  @Test("should fail a finish reason of error that carries no error object")
  func failsBareErrorFinish() async throws {
    let outcome = try await Self.run(F.sse(F.chunk("", finish: "error")))

    #expect(outcome.error == .midStream(code: "error", message: "The provider reported an error."))
  }

  @Test("should take the generation id from the response header before any chunk")
  func startsFromHeader() async throws {
    let sse = F.sse(F.errorChunk(code: 429, message: "Slow down", type: "rate_limit_exceeded", id: "gen-x"))
    let transport = OpenRouterTestTransport(headers: ["X-Generation-Id": "gen-header"], sse: sse)

    let outcome = try await Self.run(transport)

    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-header")])
    #expect(outcome.error == .rateLimited(retryAfter: nil))
  }

  @Test("should start without a generation id when the chunk's id is unusable")
  func ignoresHostileID() async throws {
    let hostile = String(repeating: "x", count: 300)

    let outcome = try await Self.run(F.sse(F.chunk("a", finish: "stop", id: hostile), "[DONE]"))

    #expect(outcome.events.first == .started(requestID: nil, generationID: nil))
  }

  @Test("should report no cost when it is absent, negative or beyond range, and never trap", arguments: ["", #","cost":-0.5"#, #","cost":1e200"#, #","cost":"lots""#])
  func toleratesHostileCost(cost: String) async throws {
    let usage = #"{"prompt_tokens":10,"completion_tokens":2"# + cost + "}"

    let outcome = try await Self.run(F.sse(F.chunk("a", finish: "stop"), F.usageChunk(usage), "[DONE]"))

    #expect(outcome.error == nil)
    #expect(outcome.events.last == .finished(usage: TokenUsage(input: 10, output: 2), reportedCost: nil, stop: .endTurn))
  }

  @Test("should keep the prompt as input when a provider reports cache reads beside it")
  func keepsPromptWhenCacheExceedsIt() async throws {
    let usage = #"{"prompt_tokens":20,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":500},"cost":1e-7}"#

    let outcome = try await Self.run(F.sse(F.chunk("a", finish: "stop"), F.usageChunk(usage), "[DONE]"))

    #expect(outcome.events.last == .finished(usage: TokenUsage(input: 20, output: 2, cacheRead: 500), reportedCost: Cost(nanoUSD: 100), stop: .endTurn))
  }

  @Test("should tolerate a usage block of the wrong shape")
  func toleratesHostileUsage() async throws {
    let usage = #"{"prompt_tokens":-4,"completion_tokens":"two","prompt_tokens_details":[]}"#

    let outcome = try await Self.run(F.sse(F.chunk("a", finish: "stop"), F.usageChunk(usage), "[DONE]"))

    #expect(outcome.events.last == .finished(usage: .zero, reportedCost: nil, stop: .endTurn))
  }

  @Test(
    "should map each error status to what it means",
    arguments: [
      (400, nil as String?, nil as String?, ModelError.invalidRequest("Invalid model specified")), (401, nil, nil, .authentication),
      (402, nil, nil, .insufficientCredits), (402, #"{"limit_source":"openrouter_in_flight_budget"}"#, "7", .rateLimited(retryAfter: .seconds(7))),
      (403, nil, nil, .forbidden("Invalid model specified")), (404, nil, nil, .noEligibleModel), (408, nil, nil, .transport(.timedOut)),
      (429, nil, "30", .rateLimited(retryAfter: .seconds(30))), (500, nil, nil, .server(status: 500)), (502, nil, nil, .server(status: 502)),
      (503, nil, "5", .noEligibleModel), (503, #"{"error_type":"provider_overloaded"}"#, "5", .overloaded(retryAfter: .seconds(5))),
    ]
  )
  func mapsStatus(status: Int, metadata: String?, retryAfter: String?, expected: ModelError) async throws {
    let headers = retryAfter.map { ["Retry-After": $0] } ?? [:]

    let outcome = try await Self.run(status: status, headers: headers, F.errorBody(code: status, message: "Invalid model specified", metadata: metadata))

    #expect(outcome.events.isEmpty)
    #expect(outcome.error == expected)
  }

  @Test("should never quote a body that is not an error object")
  func neverQuotesRawBody() async throws {
    let outcome = try await Self.run(status: 400, "<html>echo of the whole prompt</html>")

    #expect(outcome.error == .invalidRequest("The provider reported an error (status 400)."))
  }

  @Test("should redact the key wherever an error message echoes it")
  func redactsKey() async throws {
    let outcome = try await Self.run(status: 400, F.errorBody(code: 400, message: "Bad header: Bearer \(F.secret)"))

    #expect(outcome.error == .invalidRequest("Bad header: Bearer <redacted>"))
  }

  @Test("should report a data-policy mismatch as what it is")
  func mapsDataPolicy() async throws {
    let message = "No endpoints found matching your data policy (Free model publication). Configure: https://openrouter.ai/settings/privacy"

    let outcome = try await Self.run(status: 404, F.errorBody(code: 404, message: message))

    #expect(outcome.error == .dataPolicy(message))
  }

  @Test("should report a routing failure where no provider can serve as no eligible model, never a retryable overload")
  func mapsNoProvider() async throws {
    let outcome = try await Self.run(status: 503, headers: ["Retry-After": "2"], F.errorBody(code: 503, message: "No allowed providers are available for the selected model."))

    #expect(outcome.error == .noEligibleModel)
    #expect(outcome.error?.isRetryable == false)
  }

  @Test("should feed the response date to the trusted clock")
  func feedsTrustedClock() async throws {
    let clock = TrustedClock(monotonic: OpenRouterFrozenTime())
    let transport = OpenRouterTestTransport(headers: ["Date": "Thu, 01 Jan 2026 00:00:00 GMT"], sse: F.sse(F.chunk("a", finish: "stop"), "[DONE]"))

    _ = try await Self.run(transport, trustedClock: clock)

    #expect(clock.now() == .estimate(Date(timeIntervalSince1970: 1_767_225_600)))
  }

  @Test("should feed the date of an error response to the trusted clock too")
  func feedsTrustedClockOnError() async throws {
    let clock = TrustedClock(monotonic: OpenRouterFrozenTime())
    let transport = OpenRouterTestTransport(status: 500, headers: ["Date": "Thu, 01 Jan 2026 00:00:00 GMT"], sse: "")

    _ = try await Self.run(transport, trustedClock: clock)

    #expect(clock.now() == .estimate(Date(timeIntervalSince1970: 1_767_225_600)))
  }

  @Test("should map a transport failure before the response")
  func mapsTransportFailure() async throws {
    let transport = OpenRouterTestTransport(streaming: StubHTTPStreamingTransport { _ in throw URLError(.notConnectedToInternet) })

    let outcome = try await Self.run(transport)

    #expect(outcome.error == .transport(.notConnectedToInternet))
  }

  @Test("should map a connection lost mid-body")
  func mapsBodyFailure() async throws {
    let transport = OpenRouterTestTransport(streaming: StubHTTPStreamingTransport(steps: [.text(F.sse(F.chunk("a"))), .failure(URLError(.networkConnectionLost))]))

    let outcome = try await Self.run(transport)

    #expect(outcome.events == [.started(requestID: nil, generationID: "gen-1"), .textDelta("a")])
    #expect(outcome.error == .transport(.networkConnectionLost))
  }

  @Test("should retry a rate limit reported before any text and then deliver the reply")
  func retriesWithRetryingProvider() async throws {
    let calls = Mutex(0)
    let limited = F.sse(F.errorChunk(code: 429, message: "Rate limit exceeded", type: "rate_limit_exceeded", id: "gen-limited"))
    let success = F.sse(F.chunk("Recovered", finish: "stop", id: "gen-ok"), F.usageChunk(Self.usage, id: "gen-ok"), "[DONE]")
    let streaming = StubHTTPStreamingTransport { request in
      let call = calls.withLock { count in
        count += 1
        return count
      }
      return try StubHTTPStreamingTransport.response(to: request, steps: [.text(call == 1 ? limited : success)])
    }
    let provider = try F.provider(OpenRouterTestTransport(streaming: streaming))
    let clock = ManualClock(.advancesOnSleep)
    let retrying = RetryingProvider(provider, policy: RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1)), clock: clock, random: { 0 })

    let outcome = await F.drain(retrying.stream(F.request))

    #expect(outcome.error == nil)
    #expect(
      outcome.events == [
        .retrying(attempt: 1, delay: .seconds(1), cause: .rateLimited(retryAfter: nil), requestID: nil, generationID: "gen-limited"),
        .started(requestID: nil, generationID: "gen-ok"), .textDelta("Recovered"),
        .finished(usage: Self.expectedUsage, reportedCost: Cost(nanoUSD: 123_457), stop: .endTurn),
      ]
    )
    #expect(clock.requestedSleeps == [.seconds(1)])
    #expect(streaming.requests.count == 2)
  }

  @Test("should cancel the HTTP request and end with cancelled when the consumer is cancelled mid-stream")
  func cancelsMidStream() async throws {
    let bodyEnded = Signal()
    let streaming = StubHTTPStreamingTransport { request in
      let url = try #require(request.url)
      let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]))
      let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
      continuation.onTermination = { _ in bodyEnded.fire() }
      continuation.yield(Data(F.sse(F.chunk("First")).utf8))
      return HTTPStreamingResponse(response: response, body: body)
    }
    let provider = try F.provider(OpenRouterTestTransport(streaming: streaming))
    let sawText = Signal()
    let consumer = Task { () -> ModelError? in
      do throws(ModelError) {
        for try await event in provider.stream(F.request) where event == .textDelta("First") { sawText.fire() }
        return nil
      } catch {
        return error
      }
    }

    await sawText.wait()
    consumer.cancel()

    #expect(await consumer.value == .cancelled)
    await bodyEnded.wait()
  }
}

struct OpenRouterFrozenTime: MonotonicTimeSource {
  func nanoseconds() -> UInt64 { 1_000 }
}
