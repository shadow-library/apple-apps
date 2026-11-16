import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("AnthropicProvider requests", .timeLimit(.minutes(1)))
struct AnthropicRequestTests {
  private static let allowedMembers: Set<String> = ["model", "max_tokens", "stream", "system", "messages", "output_config", "cache_control"]

  private static func sent(_ request: ModelRequest) async throws -> URLRequest {
    let transport = StubHTTPExchangeTransport(transcript: AnthropicFixtures.reply)
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential())
    let outcome = await AnthropicFixtures.drain(provider.stream(request))
    #expect(outcome.error == nil)
    return try #require(transport.requests.first)
  }

  @Test("should send the pinned body and headers to the messages endpoint")
  func pinsBodyAndHeaders() async throws {
    let request = ModelRequest(
      model: "claude-opus-5-5",
      system: [ContextSegment(text: "Canon", endsStablePrefix: true), ContextSegment(text: "Chapter notes")],
      messages: [.user("Hi"), .assistant("Hello"), .user("Write the scene")],
      maxOutputTokens: 2_048,
      effort: .high
    )

    let sent = try await Self.sent(request)

    #expect(sent.httpMethod == "POST")
    #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(AnthropicFixtures.headerNames(of: sent) == ["content-type", "x-api-key", "anthropic-version"])
    #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
    #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
    #expect(
      try AnthropicFixtures.body(of: sent) == [
        "model": "claude-opus-5-5",
        "max_tokens": 2_048,
        "stream": true,
        "system": [
          ["type": "text", "text": "Canon", "cache_control": ["type": "ephemeral"]],
          ["type": "text", "text": "Chapter notes"],
        ],
        "messages": [
          ["role": "user", "content": "Hi"],
          ["role": "assistant", "content": "Hello"],
          ["role": "user", "content": "Write the scene"],
        ],
        "output_config": ["effort": "high"],
      ]
    )
  }

  @Test(
    "should give the streaming request the configured idle timeout",
    arguments: [(AnthropicConfiguration(), TimeInterval(300)), (AnthropicConfiguration(idleTimeout: .seconds(90)), TimeInterval(90))]
  )
  func setsIdleTimeout(configuration: AnthropicConfiguration, expected: TimeInterval) async throws {
    let transport = StubHTTPExchangeTransport(transcript: AnthropicFixtures.reply)
    let provider = AnthropicFixtures.provider(transport, configuration: configuration, credential: try AnthropicFixtures.credential())

    _ = await AnthropicFixtures.drain(provider.stream(AnthropicFixtures.request))

    #expect(transport.requests.map(\.timeoutInterval) == [expected])
  }

  @Test("should send each effort level under output_config", arguments: Effort.allCases)
  func sendsEffort(effort: Effort) async throws {
    var request = AnthropicFixtures.request
    request.effort = effort

    let body = try AnthropicFixtures.body(of: try await Self.sent(request))

    #expect(body["output_config"] == ["effort": .string(effort.rawValue)])
  }

  @Test("should omit output_config when neither effort nor a format is set")
  func omitsOutputConfigWithoutEffort() async throws {
    let body = try AnthropicFixtures.body(of: try await Self.sent(AnthropicFixtures.request))

    #expect(Set(body.objectValue?.keys.map { $0 } ?? []) == ["model", "max_tokens", "stream", "system", "messages"])
    #expect(body["output_config"] == nil)
  }

  @Test("should send a JSON schema format as native structured output")
  func sendsJSONSchema() async throws {
    let schema: JSONValue = ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false]
    var request = AnthropicFixtures.request
    request.format = .json(name: "chapter_plan", schema: schema)
    request.effort = .low

    let body = try AnthropicFixtures.body(of: try await Self.sent(request))

    #expect(body["output_config"] == ["effort": "low", "format": ["type": "json_schema", "schema": schema]])
  }

  @Test("should put the explicit breakpoint only on the segment that ends the stable prefix, keeping every segment's text and order")
  func placesBreakpoint() async throws {
    let texts = ["Rules / voice\n", "Canon: “Mara” — chapter 1\r\n\tend", "Today's scratch"]
    var request = AnthropicFixtures.request
    request.system = [ContextSegment(text: texts[0]), ContextSegment(text: texts[1], endsStablePrefix: true), ContextSegment(text: texts[2])]

    let sent = try await Self.sent(request)
    let system = try #require(try AnthropicFixtures.body(of: sent)["system"]?.arrayValue)

    #expect(system.map { $0["text"]?.stringValue } == texts)
    #expect(system.map { $0["cache_control"] } == [nil, ["type": "ephemeral"], nil])
    #expect(try AnthropicFixtures.body(of: sent)["cache_control"] == nil)
  }

  @Test("should omit system when the request has no segments")
  func omitsEmptySystem() async throws {
    var request = AnthropicFixtures.request
    request.system = []

    #expect(try AnthropicFixtures.body(of: try await Self.sent(request))["system"] == nil)
  }

  @Test("should ask for automatic caching of the growing conversation with a top-level cache_control")
  func cachesConversation() async throws {
    var request = AnthropicFixtures.request
    request.cachesConversation = true

    let body = try AnthropicFixtures.body(of: try await Self.sent(request))

    #expect(body["cache_control"] == ["type": "ephemeral"])
    #expect(body["system"]?[0]?["cache_control"] == nil)
  }

  @Test(
    "should never send sampling parameters",
    arguments: [
      (Effort?.none, ResponseFormat.text, false), (.low, .text, true), (.max, .json(name: "out", schema: ["type": "object"]), true),
      (nil, .json(name: "out", schema: ["type": "object"]), false),
    ]
  )
  func sendsNoSamplingParameters(effort: Effort?, format: ResponseFormat, cachesConversation: Bool) async throws {
    var request = AnthropicFixtures.request
    request.effort = effort
    request.format = format
    request.cachesConversation = cachesConversation

    let members = Set(try #require(try AnthropicFixtures.body(of: try await Self.sent(request)).objectValue).keys)

    #expect(members.isDisjoint(with: ["temperature", "top_p", "top_k", "thinking"]))
    #expect(members.isSubset(of: Self.allowedMembers))
  }

  @Test("should send nothing when the credential is for another origin")
  func refusesForeignCredential() async throws {
    let transport = StubHTTPExchangeTransport(transcript: AnthropicFixtures.reply)
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential("https://gateway.example"))

    let outcome = await AnthropicFixtures.drain(provider.stream(AnthropicFixtures.request))

    #expect(outcome.events.isEmpty)
    guard case .invalidRequest = outcome.error else {
      Issue.record("Expected invalidRequest, got \(String(describing: outcome.error))")
      return
    }
    #expect(transport.requests.isEmpty)
  }

  @Test("should send the key to a configured gateway origin that the credential names")
  func sendsToConfiguredGateway() async throws {
    let transport = StubHTTPExchangeTransport(transcript: AnthropicFixtures.reply)
    let configuration = AnthropicConfiguration(origin: try #require(URL(string: "https://gateway.example")))
    let provider = AnthropicFixtures.provider(transport, configuration: configuration, credential: try AnthropicFixtures.credential("https://gateway.example"))

    let outcome = await AnthropicFixtures.drain(provider.stream(AnthropicFixtures.request))

    #expect(outcome.error == nil)
    #expect(transport.requests.map(\.url?.absoluteString) == ["https://gateway.example/v1/messages"])
  }

  @Test("should reject an invalid request without sending it")
  func rejectsInvalidRequest() async throws {
    let transport = StubHTTPExchangeTransport(transcript: AnthropicFixtures.reply)
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential())
    var request = AnthropicFixtures.request
    request.messages = [.assistant("Hi")]

    let outcome = await AnthropicFixtures.drain(provider.stream(request))

    #expect(outcome.error == .invalidRequest("The last message must come from the user."))
    #expect(transport.requests.isEmpty)
  }
}
