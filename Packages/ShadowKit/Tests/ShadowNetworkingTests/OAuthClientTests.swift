import Foundation
import ShadowNetworking
import ShadowTestSupport
import Testing

@Suite("OAuthClient", TestTimeLimit.quick)
struct OAuthClientTests {
  private static func exchange(_ transport: StubHTTPTransport, clock: TestClock = TestClock(), sendsScope: Bool = false) async throws -> OAuthTokens {
    let client = try OAuthFixture.client(transport, clock: clock, configuration: OAuthFixture.configuration(sendsScope: sendsScope))
    let request = try client.beginAuthorization()
    let callback = try #require(URL(string: "com.example.app:/oauth2redirect?code=c%2Bd%20e&state=\(request.pending.state)&scope=ignored"))
    return try await client.completeAuthorization(callback: callback, pending: request.pending)
  }

  private static func refresh(_ transport: StubHTTPTransport, clock: TestClock = TestClock(), tokens: OAuthTokens? = nil) async throws -> OAuthTokens {
    let client = try OAuthFixture.client(transport, clock: clock)
    return try await client.refresh(tokens ?? OAuthFixture.tokens(issuedAt: clock.now))
  }

  @Test("should exchange the code as a form POST with the verifier, redirect and client id")
  func exchangesCode() async throws {
    let transport = StubHTTPTransport { try OAuthFixture.respond($0, json: OAuthFixture.tokenJSON(access: "a1", refresh: "r1")) }
    let client = try OAuthFixture.client(transport)
    let request = try client.beginAuthorization()
    let callback = try #require(URL(string: "com.example.app:/oauth2redirect?code=c%2Bd+e&state=\(request.pending.state)"))

    _ = try await client.completeAuthorization(callback: callback, pending: request.pending)

    let sent = try #require(transport.requests.first)
    #expect(transport.requests.count == 1)
    #expect(sent.url?.absoluteString == "https://login.example.com/oauth2/token")
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(sent.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(
      OAuthFixture.form(sent) == [
        "grant_type": "authorization_code", "code": "c+d e", "redirect_uri": "com.example.app:/oauth2redirect", "client_id": "client-123",
        "code_verifier": request.pending.pkce.verifier,
      ]
    )
    let body = String(decoding: sent.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("code=c%2Bd%20e"))
    #expect(body.contains("redirect_uri=com.example.app%3A%2Foauth2redirect"))
  }

  @Test("should send the scopes in token requests only when the configuration asks for it")
  func sendsScopeWhenConfigured() async throws {
    let transport = StubHTTPTransport { try OAuthFixture.respond($0, json: OAuthFixture.tokenJSON(access: "a1")) }

    _ = try await Self.exchange(transport, sendsScope: true)
    _ = try await Self.exchange(transport)

    #expect(OAuthFixture.form(transport.requests[0])["scope"] == "files.read offline_access")
    #expect(OAuthFixture.form(transport.requests[1])["scope"] == nil)
  }

  @Test("should parse the tokens and turn the relative lifetime into an instant from the request's start")
  func parsesTokens() async throws {
    let clock = TestClock()
    let issued = clock.now
    let transport = StubHTTPTransport { request in
      clock.advance(by: 5)
      return try OAuthFixture.respond(request, json: OAuthFixture.tokenJSON(access: "a1", refresh: "r1", expiresIn: "3599", scope: "files.read"))
    }

    let tokens = try await Self.exchange(transport, clock: clock)

    #expect(tokens == OAuthTokens(accessToken: "a1", issuedAt: issued, expiresAt: issued.addingTimeInterval(3599), refreshToken: "r1", scopes: ["files.read"]))
  }

  @Test("should read a lifetime given as a string, a lowercase token type and fall back to the requested scopes")
  func parsesLenientFields() async throws {
    let clock = TestClock()
    let transport = StubHTTPTransport { try OAuthFixture.respond($0, json: OAuthFixture.tokenJSON(access: "a1", expiresIn: #""60""#, type: "bearer")) }

    let tokens = try await Self.exchange(transport, clock: clock)

    #expect(tokens.expiresAt == clock.now.addingTimeInterval(60))
    #expect(tokens.tokenType == "Bearer")
    #expect(tokens.scopes == ["files.read", "offline_access"])
    #expect(tokens.refreshToken == nil)
  }

  @Test("should leave the expiry unknown when the response has no lifetime")
  func leavesExpiryUnknown() async throws {
    let transport = StubHTTPTransport { try OAuthFixture.respond($0, json: OAuthFixture.tokenJSON(access: "a1", expiresIn: nil)) }

    #expect(try await Self.exchange(transport).expiresAt == nil)
  }

  @Test(
    "should refuse a success that is not a usable bearer token response",
    arguments: [
      ("not json", OAuthError.malformedTokenResponse("The body is not a JSON token response.")),
      (#"{"token_type":"Bearer"}"#, .malformedTokenResponse("The response has no access token.")),
      (#"{"access_token":"","token_type":"Bearer"}"#, .malformedTokenResponse("The response has no access token.")),
      (#"{"access_token":"a"}"#, .malformedTokenResponse("The response has no token type.")),
      (#"{"access_token":"a","token_type":"mac"}"#, .unsupportedTokenType("mac")),
      (#"{"access_token":"a","token_type":"ma\u0007c"}"#, .unsupportedTokenType("mac")),
      (#"{"access_token":"a","token_type":"Bearer","expires_in":-1}"#, .malformedTokenResponse("The token lifetime is not a non-negative number of seconds.")),
      (#"{"access_token":"a","token_type":"Bearer","expires_in":"soon"}"#, .malformedTokenResponse("The token lifetime is not a non-negative number of seconds.")),
    ]
  )
  func refusesMalformedSuccess(json: String, expected: OAuthError) async throws {
    let transport = StubHTTPTransport { try OAuthFixture.respond($0, json: json) }

    await #expect(throws: expected) { try await Self.exchange(transport) }
  }

  @Test("should refresh as a form POST and keep the old refresh token when the response omits one")
  func refreshesKeepingRefreshToken() async throws {
    let clock = TestClock()
    let transport = StubHTTPTransport { try OAuthFixture.respond($0, json: OAuthFixture.tokenJSON(access: "a2", refresh: "")) }
    let previous = OAuthFixture.tokens(issuedAt: clock.now.addingTimeInterval(-4000))

    let tokens = try await Self.refresh(transport, clock: clock, tokens: previous)

    let sent = try #require(transport.requests.first)
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(OAuthFixture.form(sent) == ["grant_type": "refresh_token", "refresh_token": "refresh-old", "client_id": "client-123"])
    #expect(tokens.accessToken == "a2")
    #expect(tokens.refreshToken == "refresh-old")
    #expect(tokens.scopes == previous.scopes)
    #expect(tokens.issuedAt == clock.now)
  }

  @Test("should take the rotated refresh token when the response carries one")
  func takesRotatedRefreshToken() async throws {
    let transport = StubHTTPTransport { try OAuthFixture.respond($0, json: OAuthFixture.tokenJSON(access: "a2", refresh: "refresh-new")) }

    #expect(try await Self.refresh(transport).refreshToken == "refresh-new")
  }

  @Test("should ask for a new sign-in without a request when there is no refresh token")
  func refusesRefreshWithoutToken() async throws {
    let transport = StubHTTPTransport(json: "{}")
    let clock = TestClock()

    await #expect(throws: OAuthError.reauthorizationRequired) { try await Self.refresh(transport, clock: clock, tokens: OAuthFixture.tokens(refresh: nil, issuedAt: clock.now)) }
    #expect(transport.requests.isEmpty)
  }

  @Test(
    "should ask for a new sign-in when the grant is invalid or needs interaction",
    arguments: [(400, "invalid_grant"), (400, "interaction_required"), (401, "invalid_grant"), (200, "invalid_grant")]
  )
  func mapsReauthorization(status: Int, error: String) async throws {
    let transport = StubHTTPTransport { try OAuthFixture.respond($0, status: status, json: #"{"error":"\#(error)","error_description":"expired"}"#) }

    await #expect(throws: OAuthError.reauthorizationRequired) { try await Self.refresh(transport) }
  }

  @Test("should report other rejections with their status, error and description")
  func reportsRejections() async throws {
    let rejected = StubHTTPTransport { try OAuthFixture.respond($0, status: 401, json: #"{"error":"invalid_client","error_description":"Unknown\u0007 client"}"#) }
    let opaque = StubHTTPTransport { try OAuthFixture.respond($0, status: 403, json: "<html>") }

    await #expect(throws: OAuthError.tokenRequestRejected(status: 401, error: "invalid_client", description: "Unknown client")) { try await Self.refresh(rejected) }
    await #expect(throws: OAuthError.tokenRequestRejected(status: 403, error: nil, description: nil)) { try await Self.refresh(opaque) }
  }

  @Test("should report rate limits and outages as retryable with the server's Retry-After")
  func mapsRetryableStatuses() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_445_412_480))
    let limited = StubHTTPTransport { try OAuthFixture.respond($0, status: 429, json: "", headers: ["Retry-After": "30"]) }
    let dated = StubHTTPTransport { try OAuthFixture.respond($0, status: 503, json: "", headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:45 GMT"]) }
    let bare = StubHTTPTransport { try OAuthFixture.respond($0, status: 500, json: #"{"error":"server_error"}"#) }

    let errors = [
      await Self.failure { try await Self.refresh(limited, clock: clock) },
      await Self.failure { try await Self.refresh(dated, clock: clock) },
      await Self.failure { try await Self.refresh(bare, clock: clock) },
    ]

    #expect(errors == [.rateLimited(retryAfter: .seconds(30)), .serviceUnavailable(status: 503, retryAfter: .seconds(45)), .serviceUnavailable(status: 500, retryAfter: nil)])
    #expect(errors.allSatisfy { $0?.isRetryable == true })
    #expect(errors.map { $0?.retryAfter } == [.seconds(30), .seconds(45), nil])
  }

  @Test("should report transport failures as retryable and cancellation as cancelled")
  func mapsTransportFailures() async throws {
    let offline = StubHTTPTransport(error: URLError(.notConnectedToInternet))
    let cancelled = StubHTTPTransport(error: URLError(.cancelled))
    let task = StubHTTPTransport { _ in throw CancellationError() }

    let failure = await Self.failure { try await Self.refresh(offline) }
    #expect(failure == .transport(URLError(.notConnectedToInternet)))
    #expect(failure?.isRetryable == true)
    await #expect(throws: OAuthError.cancelled) { try await Self.refresh(cancelled) }
    await #expect(throws: OAuthError.cancelled) { try await Self.refresh(task) }
    #expect(OAuthError.reauthorizationRequired.isRetryable == false)
  }

  @Test("should give every error a stable code under the oauth domain")
  func namesCodes() {
    #expect(OAuthError.reauthorizationRequired.code == "oauth.reauthorization_required")
    #expect(OAuthError.stateMismatch.code == "oauth.state_mismatch")
    #expect(OAuthError.rateLimited(retryAfter: nil).code == "oauth.rate_limited")
  }

  @Test("should never show the access or refresh token in a description, debug description or mirror")
  func redactsTokens() {
    let tokens = OAuthTokens(accessToken: "secret-access", issuedAt: Date(), expiresAt: nil, refreshToken: "secret-refresh", scopes: ["files.read"])
    var dumped = ""
    dump(tokens, to: &dumped)
    var dumpedAccess = ""
    dump(tokens.accessCredential, to: &dumpedAccess)

    for text in [
      String(describing: tokens), String(reflecting: tokens), dumped, String(describing: tokens.accessCredential), String(reflecting: tokens.accessCredential), dumpedAccess,
    ] {
      #expect(!text.contains("secret-access"))
      #expect(!text.contains("secret-refresh"))
    }
    #expect(String(describing: tokens).contains("files.read"))
  }

  private static func failure(_ operation: () async throws -> OAuthTokens) async -> OAuthError? {
    do {
      _ = try await operation()
      return nil
    } catch let error as OAuthError {
      return error
    } catch {
      return nil
    }
  }
}
