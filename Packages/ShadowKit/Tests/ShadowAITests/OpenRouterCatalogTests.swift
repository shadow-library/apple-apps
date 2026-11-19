import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("OpenRouterProvider key check and model list", TestTimeLimit.quick)
struct OpenRouterCatalogTests {
  private typealias F = OpenRouterFixtures

  private static func provider(_ plain: StubHTTPTransport, trustedClock: TrustedClock? = nil) throws -> OpenRouterProvider {
    try F.provider(StubHTTPExchangeTransport(plain: plain), trustedClock: trustedClock)
  }

  private static func validate(_ plain: StubHTTPTransport) async throws -> CredentialStatus {
    try await provider(plain).validate(try makeCredential(F.origin, secret: F.secret))
  }

  @Test("should call the key endpoint with the key and report its label")
  func validatesWithLabel() async throws {
    let plain = StubHTTPTransport(json: #"{"data":{"label":"sk-or-v1-au7...890","limit":null,"usage":0.25,"is_free_tier":false}}"#)

    let status = try await Self.validate(plain)

    #expect(status == .valid(label: "sk-or-v1-au7...890"))
    let sent = try #require(plain.requests.first)
    #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/key")
    #expect(sent.httpMethod == "GET")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
  }

  @Test("should report a key as valid without a label when the body has none", arguments: ["{}", #"{"data":{"label":""}}"#, "not json", #"{"data":{"label":42}}"#])
  func validatesWithoutLabel(body: String) async throws {
    #expect(try await Self.validate(StubHTTPTransport(json: body)) == .valid(label: nil))
  }

  @Test("should report a rejected key as invalid")
  func reportsInvalid() async throws {
    let status = try await Self.validate(StubHTTPTransport(statusCode: 401, json: F.errorBody(code: 401, message: "User not found.")))

    #expect(status == .invalid)
  }

  @Test(
    "should report a check that could not finish as unverified",
    arguments: [
      (StubHTTPTransport(statusCode: 500, json: ""), ModelError.server(status: 500)), (StubHTTPTransport(statusCode: 429, json: ""), .rateLimited(retryAfter: nil)),
      (StubHTTPTransport(error: URLError(.notConnectedToInternet)), .transport(.notConnectedToInternet)),
    ]
  )
  func reportsUnverified(plain: StubHTTPTransport, cause: ModelError) async throws {
    #expect(try await Self.validate(plain) == .unverified(cause))
  }

  @Test("should refuse to check a key bound to another origin without sending it")
  func refusesForeignKey() async throws {
    let plain = StubHTTPTransport(json: "{}")

    await #expect(throws: ModelError.invalidRequest("The key belongs to another origin, so it was not sent.")) {
      try await Self.provider(plain).validate(try makeCredential("https://api.anthropic.com", secret: F.secret))
    }
    #expect(plain.requests.isEmpty)
  }

  @Test("should throw cancelled rather than report a cancelled check")
  func throwsCancelled() async throws {
    await #expect(throws: ModelError.cancelled) { try await Self.validate(StubHTTPTransport(error: URLError(.cancelled))) }
  }

  @Test("should read the published model list without a key, with exact prices, context and schema support")
  func readsModels() async throws {
    let body = """
      {"data":[
        {"id":"anthropic/claude-sonnet-5","name":"Anthropic: Claude Sonnet 5","context_length":1000000,
         "pricing":{"prompt":"0.000003","completion":"0.000015","input_cache_read":"0.0000003","request":"0"},
         "top_provider":{"context_length":1000000,"max_completion_tokens":64000,"is_moderated":true},
         "supported_parameters":["max_tokens","reasoning","response_format","structured_outputs"],"architecture":{"modality":"text->text"}},
        {"id":"meta-llama/llama-4:free","pricing":{"prompt":"0","completion":"0"},"supported_parameters":["max_tokens"],"top_provider":{"context_length":131072}},
        {"id":"openrouter/auto","name":"Auto Router","pricing":{"prompt":"-1","completion":"-1"}},
        {"id":"vendor/odd","context_length":"big","pricing":"free","supported_parameters":"all","top_provider":null},
        {"name":"No id"},
        {"id":""},
        42
      ]}
      """
    let plain = StubHTTPTransport(json: body)

    let models = try await Self.provider(plain).models()

    #expect(
      models == [
        RemoteModel(
          id: "anthropic/claude-sonnet-5", name: "Anthropic: Claude Sonnet 5", contextLength: 1_000_000, maxOutputTokens: 64_000, supportsJSONSchema: true,
          inputPrice: Cost(nanoUSD: 3_000_000_000), outputPrice: Cost(nanoUSD: 15_000_000_000)
        ),
        RemoteModel(id: "meta-llama/llama-4:free", contextLength: 131_072, supportsJSONSchema: false, inputPrice: .zero, outputPrice: .zero),
        RemoteModel(id: "openrouter/auto", name: "Auto Router"),
        RemoteModel(id: "vendor/odd"),
      ]
    )
    let sent = try #require(plain.requests.first)
    #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/models")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test("should fail a model list that is not a list")
  func failsMalformedModels() async throws {
    await #expect(throws: ModelError.malformedResponse("The provider's model list could not be read.")) {
      try await Self.provider(StubHTTPTransport(json: #"{"data":{"id":"x"}}"#)).models()
    }
  }

  @Test("should map a failed model list request")
  func mapsModelsFailure() async throws {
    await #expect(throws: ModelError.server(status: 502)) { try await Self.provider(StubHTTPTransport(statusCode: 502, json: "")).models() }
  }

  @Test("should feed the model list's response date to the trusted clock")
  func feedsTrustedClock() async throws {
    let clock = TrustedClock(monotonic: OpenRouterFrozenTime())
    let plain = StubHTTPTransport { request in
      try StubHTTPTransport.response(to: request, statusCode: 200, data: Data(#"{"data":[]}"#.utf8), headers: ["Date": "Thu, 01 Jan 2026 00:00:00 GMT"])
    }

    _ = try await Self.provider(plain, trustedClock: clock).models()

    #expect(clock.now() == .estimate(Date(timeIntervalSince1970: 1_767_225_600)))
  }
}
