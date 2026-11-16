import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("OpenRouterProvider requests", .timeLimit(.minutes(1)))
struct OpenRouterRequestTests {
  private static let success = OpenRouterFixtures.sse(OpenRouterFixtures.chunk("ok", finish: "stop"), "[DONE]")

  private static func sentRequest(
    _ request: ModelRequest,
    configuration: OpenRouterConfiguration = .init()
  ) async throws -> URLRequest {
    let transport = OpenRouterTestTransport(sse: success)
    let outcome = await OpenRouterFixtures.drain(try OpenRouterFixtures.provider(transport, configuration: configuration).stream(request))
    #expect(outcome.error == nil)
    return try #require(transport.streaming.requests.first)
  }

  @Test("should post the pinned body and headers for a fixed request")
  func pinsBodyAndHeaders() async throws {
    let request = ModelRequest(
      model: "anthropic/claude-sonnet-5",
      system: [ContextSegment(text: "You are a careful editor.", endsStablePrefix: true), ContextSegment(text: "Chapter 3 notes.")],
      messages: [.user("Hi"), .assistant("Hello"), .user("Edit this")],
      maxOutputTokens: 1024,
      effort: .high,
      cachesConversation: true
    )
    let url = try #require(URL(string: "https://shadowlibrary.example"))

    let sent = try await Self.sentRequest(request, configuration: OpenRouterConfiguration(applicationTitle: "Shadow Library", applicationURL: url))

    #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
    #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(sent.value(forHTTPHeaderField: "HTTP-Referer") == "https://shadowlibrary.example")
    #expect(sent.value(forHTTPHeaderField: "X-OpenRouter-Title") == "Shadow Library")
    let expected = """
      {"max_completion_tokens":1024,"model":"anthropic/claude-sonnet-5","reasoning":{"effort":"high","exclude":true},"stream":true,"messages":[\
      {"role":"system","content":[{"type":"text","text":"You are a careful editor.","cache_control":{"type":"ephemeral"}},{"type":"text","text":"Chapter 3 notes."}]},\
      {"role":"user","content":"Hi"},\
      {"role":"assistant","content":[{"type":"text","text":"Hello","cache_control":{"type":"ephemeral"}}]},\
      {"role":"user","content":"Edit this"}]}
      """
    #expect(try OpenRouterFixtures.json(sent.httpBody) == OpenRouterFixtures.json(expected))
  }

  @Test("should send a lone system segment as text and no reasoning, format or attribution when none is asked for")
  func omitsOptionalMembers() async throws {
    let sent = try await Self.sentRequest(OpenRouterFixtures.request)

    let expected = """
      {"max_completion_tokens":256,"model":"anthropic/claude-sonnet-5","stream":true,"messages":[{"role":"system","content":"Be brief."},{"role":"user","content":"Hi"}]}
      """
    #expect(try OpenRouterFixtures.json(sent.httpBody) == OpenRouterFixtures.json(expected))
    #expect(sent.value(forHTTPHeaderField: "HTTP-Referer") == nil)
    #expect(sent.value(forHTTPHeaderField: "X-OpenRouter-Title") == nil)
  }

  @Test("should map each effort onto the documented reasoning effort and exclude reasoning text", arguments: Effort.allCases)
  func mapsEffort(effort: Effort) async throws {
    var request = OpenRouterFixtures.request
    request.effort = effort

    let body = try OpenRouterFixtures.json(try await Self.sentRequest(request).httpBody)

    #expect(body["reasoning"] == ["effort": .string(effort.rawValue), "exclude": true])
  }

  @Test("should ask for native schema mode, strict, and route only to providers that support every parameter, when the request wants JSON")
  func sendsNativeSchema() async throws {
    let schema: JSONValue = ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false]
    let request = ModelRequest(
      model: "anthropic/claude-sonnet-5",
      system: [ContextSegment(text: "Name chapters.")],
      messages: [.user("Name chapter 3.")],
      maxOutputTokens: 512,
      effort: .low,
      format: .json(name: "chapter_title", schema: schema)
    )

    let sent = try await Self.sentRequest(request)

    let expected = """
      {
        "max_completion_tokens": 512,
        "messages": [
          {"content": "Name chapters.", "role": "system"},
          {"content": "Name chapter 3.", "role": "user"}
        ],
        "model": "anthropic/claude-sonnet-5",
        "provider": {"require_parameters": true},
        "reasoning": {"effort": "low", "exclude": true},
        "response_format": {
          "json_schema": {
            "name": "chapter_title",
            "schema": {"additionalProperties": false, "properties": {"title": {"type": "string"}}, "required": ["title"], "type": "object"},
            "strict": true
          },
          "type": "json_schema"
        },
        "stream": true
      }
      """
    #expect(try OpenRouterFixtures.json(sent.httpBody) == OpenRouterFixtures.json(expected))
  }

  @Test("should leave provider routing alone for a text request")
  func omitsProviderForText() async throws {
    let body = try OpenRouterFixtures.json(try await Self.sentRequest(OpenRouterFixtures.request).httpBody)

    #expect(body["provider"] == nil)
    #expect(body["response_format"] == nil)
  }

  @Test(
    "should report a JSON request that no provider supporting every parameter can serve as no eligible model",
    arguments: [
      (404, "No endpoints found that can handle the requested parameters."),
      (503, "No allowed providers are available for the selected model."),
    ]
  )
  func mapsNoProviderForJSON(status: Int, message: String) async throws {
    var request = OpenRouterFixtures.request
    request.format = .json(name: "answer", schema: ["type": "object"])
    let transport = OpenRouterTestTransport(status: status, headers: ["Retry-After": "3"], sse: OpenRouterFixtures.errorBody(code: status, message: message))

    let outcome = await OpenRouterFixtures.drain(try OpenRouterFixtures.provider(transport).stream(request))

    #expect(outcome.events.isEmpty)
    #expect(outcome.error == .noEligibleModel)
    let body = try OpenRouterFixtures.json(transport.streaming.requests.first?.httpBody)
    #expect(body["provider"] == ["require_parameters": true])
  }

  @Test("should send no message without a system segment and leave the conversation uncached by default")
  func omitsSystemAndBreakpoints() async throws {
    let request = ModelRequest(model: "m/x", system: [], messages: [.user("One"), .assistant("Two"), .user("Three")], maxOutputTokens: 8)

    let body = try OpenRouterFixtures.json(try await Self.sentRequest(request).httpBody)

    #expect(body["messages"] == [["role": "user", "content": "One"], ["role": "assistant", "content": "Two"], ["role": "user", "content": "Three"]])
  }

  @Test("should drop a title a header cannot carry")
  func dropsUnsafeTitle() async throws {
    let sent = try await Self.sentRequest(OpenRouterFixtures.request, configuration: OpenRouterConfiguration(applicationTitle: "Bibliothèque\r\nX-Evil: 1"))

    #expect(sent.value(forHTTPHeaderField: "X-OpenRouter-Title") == nil)
  }

  @Test("should never send the key to an origin it is not bound to")
  func refusesForeignOrigin() async throws {
    let transport = OpenRouterTestTransport(sse: Self.success)
    let provider = try OpenRouterFixtures.provider(transport, origin: "https://gateway.example")

    let outcome = await OpenRouterFixtures.drain(provider.stream(OpenRouterFixtures.request))

    #expect(outcome.error == .invalidRequest("The key belongs to another origin, so it was not sent."))
    #expect(transport.streaming.requests.isEmpty)
  }

  @Test("should follow a configured origin when the key is bound to it")
  func followsConfiguredOrigin() async throws {
    let transport = OpenRouterTestTransport(sse: Self.success)
    let origin = try #require(URL(string: "https://eu.openrouter.ai"))
    let provider = try OpenRouterFixtures.provider(transport, origin: "https://eu.openrouter.ai", configuration: OpenRouterConfiguration(origin: origin))

    let outcome = await OpenRouterFixtures.drain(provider.stream(OpenRouterFixtures.request))

    #expect(outcome.error == nil)
    #expect(transport.streaming.requests.first?.url?.absoluteString == "https://eu.openrouter.ai/api/v1/chat/completions")
  }

  @Test("should reject an invalid request before reading the key or sending anything")
  func validatesFirst() async throws {
    let transport = OpenRouterTestTransport(sse: Self.success)
    let reads = RunCounter()
    let credential = try makeCredential(OpenRouterFixtures.origin)
    let provider = OpenRouterProvider(
      credential: { () async throws(ModelError) in
        reads.increment()
        return credential
      },
      transport: transport
    )
    var request = OpenRouterFixtures.request
    request.messages = []

    let outcome = await OpenRouterFixtures.drain(provider.stream(request))

    #expect(outcome.error == .invalidRequest("The request has no messages."))
    #expect(reads.value == 0)
    #expect(transport.streaming.requests.isEmpty)
  }

  @Test("should do no work until the stream is iterated")
  func isLazy() async throws {
    let transport = OpenRouterTestTransport(sse: Self.success)
    let reads = RunCounter()
    let credential = try makeCredential(OpenRouterFixtures.origin)
    let provider = OpenRouterProvider(
      credential: { () async throws(ModelError) in
        reads.increment()
        return credential
      },
      transport: transport
    )

    let stream = provider.stream(OpenRouterFixtures.request)
    try await Task.sleep(for: .milliseconds(20))

    #expect(reads.value == 0)
    #expect(transport.streaming.requests.isEmpty)
    _ = await OpenRouterFixtures.drain(stream)
    #expect(reads.value == 1)
    #expect(transport.streaming.requests.count == 1)
  }

  @Test("should surface a failure to read the key without sending anything")
  func surfacesCredentialFailure() async throws {
    let transport = OpenRouterTestTransport(sse: Self.success)
    let provider = OpenRouterProvider(credential: { () async throws(ModelError) in throw .authentication }, transport: transport)

    let outcome = await OpenRouterFixtures.drain(provider.stream(OpenRouterFixtures.request))

    #expect(outcome.error == .authentication)
    #expect(transport.streaming.requests.isEmpty)
  }
}
