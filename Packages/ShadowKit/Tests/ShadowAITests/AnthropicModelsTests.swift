import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowAI

private let firstPage = #"""
  {
    "data": [
      {
        "id": "claude-opus-5-5",
        "type": "model",
        "display_name": "Claude Opus 5.5",
        "created_at": "2026-09-21T00:00:00Z",
        "lifecycle": "active",
        "line": "opus",
        "max_input_tokens": 1000000,
        "max_tokens": 128000,
        "capabilities": {
          "batch": {"supported": true},
          "effort": {"supported": true, "low": {"supported": true}, "medium": {"supported": true}, "high": {"supported": true}, "xhigh": {"supported": true}, "max": {"supported": true}},
          "structured_outputs": {"supported": true},
          "thinking": {"supported": true, "types": {"adaptive": {"supported": true}, "enabled": {"supported": false}}},
          "a_future_capability": {"supported": true}
        },
        "a_future_field": 42
      }
    ],
    "first_id": "claude-opus-5-5",
    "has_more": true,
    "last_id": "claude-opus-5-5"
  }
  """#

private let secondPage = #"""
  {
    "data": [
      {
        "id": "claude-haiku-4-5-20251001",
        "type": "model",
        "display_name": "Claude Haiku 4.5",
        "created_at": "2025-10-01T00:00:00Z",
        "max_input_tokens": 200000,
        "max_tokens": 64000,
        "capabilities": {"structured_outputs": {"supported": false}}
      },
      {
        "id": "claude-unknown",
        "type": "model",
        "display_name": "Claude Unknown",
        "created_at": "1970-01-01T00:00:00Z",
        "max_input_tokens": null,
        "max_tokens": null,
        "capabilities": null
      }
    ],
    "first_id": "claude-haiku-4-5-20251001",
    "has_more": false,
    "last_id": "claude-unknown"
  }
  """#

private let emptyPage = #"{"data": [], "first_id": null, "has_more": false, "last_id": null}"#

@Suite("AnthropicProvider models and validation", .timeLimit(.minutes(1)))
struct AnthropicModelsTests {
  private static func plain(status: Int = 200, json: String, headers: [String: String] = [:]) -> AnthropicTestTransport {
    AnthropicTestTransport(
      plain: StubHTTPTransport { request in try StubHTTPTransport.response(to: request, statusCode: status, data: Data(json.utf8), headers: headers) }
    )
  }

  private static func query(_ request: URLRequest, _ name: String) -> String? {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
  }

  @Test("should follow pagination to the end and map ids, names and capabilities")
  func listsAllPages() async throws {
    let transport = AnthropicTestTransport(
      plain: StubHTTPTransport { request in
        let after = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "after_id" }?.value
        return try StubHTTPTransport.response(to: request, statusCode: 200, data: Data((after == nil ? firstPage : secondPage).utf8))
      }
    )
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential())

    let models = try await provider.models()

    #expect(
      models == [
        RemoteModel(id: "claude-opus-5-5", name: "Claude Opus 5.5", contextLength: 1_000_000, maxOutputTokens: 128_000, supportsJSONSchema: true),
        RemoteModel(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", contextLength: 200_000, maxOutputTokens: 64_000, supportsJSONSchema: false),
        RemoteModel(id: "claude-unknown", name: "Claude Unknown"),
      ]
    )
    let requests = transport.plain.requests
    #expect(requests.map { $0.url?.path() } == ["/v1/models", "/v1/models"])
    #expect(requests.map { Self.query($0, "after_id") } == [nil, "claude-opus-5-5"])
    #expect(requests.map { Self.query($0, "limit") } == ["1000", "1000"])
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.timeoutInterval == 30 })
    #expect(requests.allSatisfy { AnthropicFixtures.headerNames(of: $0) == ["x-api-key", "anthropic-version"] })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test" && $0.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21" })
  }

  @Test("should return an empty list")
  func listsNothing() async throws {
    let provider = AnthropicFixtures.provider(Self.plain(json: emptyPage), credential: try AnthropicFixtures.credential())

    #expect(try await provider.models() == [])
  }

  @Test("should fail as malformed when a page says there is more but names no cursor")
  func failsWithoutCursor() async throws {
    let page = #"{"data": [], "first_id": null, "has_more": true, "last_id": null}"#
    let provider = AnthropicFixtures.provider(Self.plain(json: page), credential: try AnthropicFixtures.credential())

    await #expect(throws: ModelError.malformedResponse("The provider's model list does not say where its next page starts.")) { try await provider.models() }
  }

  @Test("should map an error response from the models endpoint")
  func mapsModelsError() async throws {
    let body = #"{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}"#
    let provider = AnthropicFixtures.provider(Self.plain(status: 401, json: body), credential: try AnthropicFixtures.credential())

    await #expect(throws: ModelError.authentication) { try await provider.models() }
  }

  @Test("should report a key the models endpoint accepts as valid, using only the candidate key")
  func validatesKey() async throws {
    let transport = Self.plain(json: emptyPage)
    let credentialCalls = RunCounter()
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential(secret: "sk-configured"), credentialCalls: credentialCalls)

    let status = try await provider.validate(try AnthropicFixtures.credential(secret: "sk-candidate"))

    #expect(status == .valid(label: nil))
    #expect(transport.plain.requests.count == 1)
    #expect(transport.plain.requests.first?.value(forHTTPHeaderField: "x-api-key") == "sk-candidate")
    #expect(transport.plain.requests.first.flatMap { Self.query($0, "limit") } == "1")
    #expect(transport.plain.requests.first?.timeoutInterval == 30)
    #expect(credentialCalls.value == 0)
  }

  @Test("should report a key the provider rejects as invalid")
  func reportsInvalidKey() async throws {
    let body = #"{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}, "request_id": "req_1"}"#
    let provider = AnthropicFixtures.provider(Self.plain(status: 401, json: body), credential: try AnthropicFixtures.credential())

    #expect(try await provider.validate(try AnthropicFixtures.credential()) == .invalid)
  }

  @Test(
    "should report a key it could not check as unverified",
    arguments: [
      (529, #"{"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}"#, ModelError.overloaded(retryAfter: nil)),
      (403, #"{"type": "error", "error": {"type": "permission_error", "message": "Region blocked"}}"#, .forbidden("Region blocked")),
      (200, "not json", .malformedResponse("The provider's model list could not be read.")),
    ]
  )
  func reportsUnverified(status: Int, body: String, expected: ModelError) async throws {
    let provider = AnthropicFixtures.provider(Self.plain(status: status, json: body), credential: try AnthropicFixtures.credential())

    #expect(try await provider.validate(try AnthropicFixtures.credential()) == .unverified(expected))
  }

  @Test("should report a key as unverified when the connection fails")
  func reportsUnverifiedOffline() async throws {
    let transport = AnthropicTestTransport(plain: StubHTTPTransport(error: URLError(.notConnectedToInternet)))
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential())

    #expect(try await provider.validate(try AnthropicFixtures.credential()) == .unverified(.transport(.notConnectedToInternet)))
  }

  @Test("should refuse a key for another origin without sending it")
  func refusesForeignKey() async throws {
    let transport = Self.plain(json: emptyPage)
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential())

    await #expect(throws: ModelError.invalidRequest("The key belongs to a different address than this provider.")) {
      try await provider.validate(try AnthropicFixtures.credential("https://gateway.example"))
    }
    #expect(transport.requests.isEmpty)
  }

  @Test("should feed the Date header of a validation response to the trusted clock")
  func feedsTrustedClockOnValidate() async throws {
    let clock = TrustedClock(monotonic: AnthropicFrozenTime())
    let transport = Self.plain(json: emptyPage, headers: ["Date": "Tue, 10 Nov 2026 12:00:00 GMT"])
    let provider = AnthropicFixtures.provider(transport, credential: try AnthropicFixtures.credential(), trustedClock: clock)

    _ = try await provider.validate(try AnthropicFixtures.credential())

    #expect(clock.now() == .estimate(Date(timeIntervalSince1970: 1_794_312_000)))
  }
}
