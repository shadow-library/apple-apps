import Foundation
import ShadowCore
import ShadowNetworking
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("OpenRouter generation lookup", TestTimeLimit.quick)
struct OpenRouterGenerationTests {
  private static func lookup(_ transport: StubHTTPTransport, origin: String = OpenRouterFixtures.origin) throws -> OpenRouterGenerationLookup {
    let credential = try makeCredential(origin, secret: OpenRouterFixtures.secret)
    return OpenRouterGenerationLookup(credential: { () async throws(ModelError) in credential }, transport: transport)
  }

  private static func body(_ fields: String) -> String { "{\"data\":{\"id\":\"gen-1\",\(fields)}}" }

  private static func failure(_ transport: StubHTTPTransport) async throws -> OpenRouterGenerationError? {
    let lookup = try lookup(transport)
    do throws(OpenRouterGenerationError) {
      _ = try await lookup.generation(id: "gen-1")
      return nil
    } catch {
      return error
    }
  }

  @Test("should read the total cost and native token counts from a recorded response")
  func readsRecordedResponse() async throws {
    let transport = StubHTTPTransport(json: Self.body("\"total_cost\":0.000123456,\"native_tokens_prompt\":120,\"native_tokens_completion\":45"))
    let generation = try await Self.lookup(transport).generation(id: "gen-1")
    #expect(generation == OpenRouterGeneration(id: "gen-1", cost: Cost(nanoUSD: 123_456), nativeInputTokens: 120, nativeOutputTokens: 45))
  }

  @Test("should send the id as a query item with the bearer key to the generation endpoint")
  func sendsRequest() async throws {
    let transport = StubHTTPTransport(json: Self.body("\"total_cost\":\"0.5\""))
    _ = try await Self.lookup(transport).generation(id: "gen-a&b=c")
    let request = try #require(transport.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path() == "/api/v1/generation")
    #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "id", value: "gen-a&b=c")])
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(OpenRouterFixtures.secret)")
  }

  @Test(
    "should parse cost decimals exactly without floating point rounding",
    arguments: [
      ("\"0.000000001\"", 1), ("\"0.00000123\"", 1_230), ("\"1.234567891\"", 1_234_567_891), ("\"1.2345678914\"", 1_234_567_891), ("\"1.2345678915\"", 1_234_567_892),
      ("\"1e-6\"", 1_000), ("\"0\"", 0), ("0.1", 100_000_000), ("12", 12_000_000_000), ("\"123456789.123456789\"", 123_456_789_123_456_789),
    ])
  func parsesExactly(text: String, nano: Int64) async throws {
    let transport = StubHTTPTransport(json: Self.body("\"total_cost\":\(text)"))
    #expect(try await Self.lookup(transport).generation(id: "gen-1").cost == Cost(nanoUSD: nano))
  }

  @Test("should report a missing generation, a null cost and a missing cost as not ready")
  func notReady() async throws {
    #expect(try await Self.failure(StubHTTPTransport(statusCode: 404, json: "{\"error\":{\"code\":404,\"message\":\"Generation not found\"}}")) == .notReady)
    #expect(try await Self.failure(StubHTTPTransport(json: Self.body("\"total_cost\":null"))) == .notReady)
    #expect(try await Self.failure(StubHTTPTransport(json: Self.body("\"model\":\"x\""))) == .notReady)
  }

  @Test("should map an unauthorised response to authentication")
  func authentication() async throws {
    #expect(try await Self.failure(StubHTTPTransport(statusCode: 401, json: "{\"error\":{\"code\":401,\"message\":\"No auth\"}}")) == .authentication)
    #expect(try await Self.failure(StubHTTPTransport(statusCode: 403)) == .authentication)
  }

  @Test("should map throttling, server faults and other statuses to typed errors")
  func statuses() async throws {
    let throttled = StubHTTPTransport { request in try StubHTTPTransport.response(to: request, statusCode: 429, headers: ["Retry-After": "7"]) }
    #expect(try await Self.failure(throttled) == .rateLimited(retryAfter: .seconds(7)))
    #expect(try await Self.failure(StubHTTPTransport(statusCode: 502)) == .server(status: 502))
    #expect(try await Self.failure(StubHTTPTransport(statusCode: 400)) == .rejected(status: 400))
    #expect(try await Self.failure(StubHTTPTransport(statusCode: 524)) == .server(status: 524))
    #expect(try await Self.failure(StubHTTPTransport(statusCode: 529)) == .server(status: 529))
    #expect(try await Self.failure(StubHTTPTransport(statusCode: 402)) == .rejected(status: 402))
    #expect(OpenRouterGenerationError.server(status: 529).isRetryable)
    #expect(!OpenRouterGenerationError.rejected(status: 402).isRetryable)
  }

  @Test("should map a transport failure and cancellation")
  func transportFailures() async throws {
    #expect(try await Self.failure(StubHTTPTransport(error: URLError(.timedOut))) == .transport(.timedOut))
    #expect(try await Self.failure(StubHTTPTransport(error: URLError(.cancelled))) == .cancelled)
  }

  @Test("should reject malformed bodies and negative or unreadable costs")
  func malformed() async throws {
    #expect(try await Self.failure(StubHTTPTransport(json: "not json")) == .malformed)
    #expect(try await Self.failure(StubHTTPTransport(json: "{\"data\":null}")) == .malformed)
    #expect(try await Self.failure(StubHTTPTransport(json: Self.body("\"total_cost\":\"-0.5\""))) == .malformed)
    #expect(try await Self.failure(StubHTTPTransport(json: Self.body("\"total_cost\":\"abc\""))) == .malformed)
    #expect(try await Self.failure(StubHTTPTransport(json: Self.body("\"total_cost\":{}"))) == .malformed)
  }

  @Test("should not send the key when the credential belongs to another origin")
  func foreignOrigin() async throws {
    let transport = StubHTTPTransport(json: Self.body("\"total_cost\":1"))
    let lookup = try Self.lookup(transport, origin: "https://example.com")
    do throws(OpenRouterGenerationError) {
      _ = try await lookup.generation(id: "gen-1")
      Issue.record("expected a failure")
    } catch {
      #expect(error == .authentication)
    }
    #expect(transport.requests.isEmpty)
  }
}
