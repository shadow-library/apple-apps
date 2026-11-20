import Foundation
import ShadowNetworking
import ShadowTestSupport
import Testing

@Suite("OAuth authorization", TestTimeLimit.quick)
struct OAuthAuthorizationTests {
  private static func parameters(_ url: URL) throws -> [String: String] {
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(Set(items.map(\.name)).count == items.count)
    return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
  }

  private static func callback(_ query: String, base: String = "com.example.app:/oauth2redirect") throws -> URL {
    try #require(URL(string: "\(base)?\(query)"))
  }

  private static func begin(_ transport: StubHTTPTransport = StubHTTPTransport(json: "{}")) throws -> (OAuthClient, OAuthAuthorizationRequest) {
    let client = try OAuthFixture.client(transport)
    return (client, try client.beginAuthorization())
  }

  @Test("should build the authorization address with the client, redirect, scopes, state, challenge and extra parameters")
  func buildsAuthorizationURL() throws {
    let configuration = try OAuthFixture.configuration(parameters: ["prompt": "select_account", "access_type": "offline"])
    let client = try OAuthFixture.client(StubHTTPTransport(json: "{}"), configuration: configuration, random: OAuthFixture.countingRandom())

    let request = try client.beginAuthorization()

    let parameters = try Self.parameters(request.url)
    #expect(request.url.host() == "login.example.com")
    #expect(request.url.path() == "/oauth2/authorize")
    #expect(parameters["tenant"] == "common")
    #expect(parameters["response_type"] == "code")
    #expect(parameters["client_id"] == "client-123")
    #expect(parameters["redirect_uri"] == "com.example.app:/oauth2redirect")
    #expect(parameters["scope"] == "files.read offline_access")
    #expect(parameters["state"] == request.pending.state)
    #expect(parameters["code_challenge"] == request.pending.pkce.challenge)
    #expect(parameters["code_challenge_method"] == "S256")
    #expect(parameters["prompt"] == "select_account")
    #expect(parameters["access_type"] == "offline")
    #expect(request.pending.state.count == 43)
    #expect(request.pending.state != request.pending.pkce.verifier)
    #expect(OAuthPKCE(verifier: request.pending.pkce.verifier)?.challenge == request.pending.pkce.challenge)
  }

  @Test("should percent-encode spaces, colons and slashes in the query and order the extra parameters")
  func encodesQuery() throws {
    let configuration = try OAuthFixture.configuration(scopes: ["https://example.com/auth/files", "offline_access"], parameters: ["b": "2 3", "a": "1"])
    let client = try OAuthFixture.client(StubHTTPTransport(json: "{}"), configuration: configuration)

    let query = try #require(try client.beginAuthorization().url.query(percentEncoded: true))

    #expect(query.contains("redirect_uri=com.example.app%3A%2Foauth2redirect"))
    #expect(query.contains("scope=https%3A%2F%2Fexample.com%2Fauth%2Ffiles%20offline_access"))
    #expect(query.hasSuffix("&a=1&b=2%203"))
    #expect(query.hasPrefix("tenant=common&response_type=code&"))
  }

  @Test("should draw a new state and verifier for every authorization")
  func drawsFreshSecrets() throws {
    let (client, first) = try Self.begin()
    let second = try client.beginAuthorization()

    #expect(first.pending.state != second.pending.state)
    #expect(first.pending.pkce.verifier != second.pending.pkce.verifier)
  }

  @Test(
    "should refuse a callback that returns elsewhere than the redirect URI",
    arguments: ["com.example.other:/oauth2redirect", "com.example.app:/oauth2redirect/extra", "com.example.app:/other", "com.example.app://host/oauth2redirect"]
  )
  func refusesForeignRedirect(base: String) async throws {
    let transport = StubHTTPTransport(json: "{}")
    let (client, request) = try Self.begin(transport)

    await #expect(throws: OAuthError.redirectMismatch) {
      try await client.completeAuthorization(callback: Self.callback("code=abc&state=\(request.pending.state)", base: base), pending: request.pending)
    }
    #expect(transport.requests.isEmpty)
  }

  @Test("should accept a callback whose scheme differs only in case")
  func acceptsSchemeCase() async throws {
    let transport = StubHTTPTransport { try OAuthFixture.respond($0, json: OAuthFixture.tokenJSON(access: "a")) }
    let (client, request) = try Self.begin(transport)

    let tokens = try await client.completeAuthorization(
      callback: Self.callback("code=abc&state=\(request.pending.state)", base: "COM.Example.App:/oauth2redirect"), pending: request.pending)

    #expect(tokens.accessToken == "a")
  }

  @Test(
    "should refuse a callback with a missing or wrong state, even when it reports an error", arguments: ["code=abc", "code=abc&state=forged", "error=access_denied&state=forged"])
  func refusesWrongState(query: String) async throws {
    let transport = StubHTTPTransport(json: "{}")
    let (client, request) = try Self.begin(transport)

    await #expect(throws: OAuthError.stateMismatch) { try await client.completeAuthorization(callback: Self.callback(query), pending: request.pending) }
    #expect(transport.requests.isEmpty)
  }

  @Test("should refuse a callback that repeats a parameter")
  func refusesRepeatedParameter() async throws {
    let transport = StubHTTPTransport(json: "{}")
    let (client, request) = try Self.begin(transport)
    let state = request.pending.state

    await #expect(throws: OAuthError.invalidCallback(#"The parameter "state" appears more than once."#)) {
      try await client.completeAuthorization(callback: Self.callback("code=abc&state=\(state)&state=\(state)"), pending: request.pending)
    }
    #expect(transport.requests.isEmpty)
  }

  @Test("should report a declined sign-in apart from other provider errors")
  func reportsProviderErrors() async throws {
    let transport = StubHTTPTransport(json: "{}")
    let (client, request) = try Self.begin(transport)
    let state = request.pending.state

    await #expect(throws: OAuthError.accessDenied(description: "The user said no")) {
      try await client.completeAuthorization(callback: Self.callback("error=access_denied&error_description=The+user%20said+no&state=\(state)"), pending: request.pending)
    }
    await #expect(throws: OAuthError.authorizationFailed(error: "invalid_scope", description: nil)) {
      try await client.completeAuthorization(callback: Self.callback("error=invalid_scope&state=\(state)"), pending: request.pending)
    }
    #expect(transport.requests.isEmpty)
  }

  @Test("should refuse a callback without a code", arguments: ["", "code=&"])
  func refusesMissingCode(prefix: String) async throws {
    let transport = StubHTTPTransport(json: "{}")
    let (client, request) = try Self.begin(transport)

    await #expect(throws: OAuthError.missingAuthorizationCode) {
      try await client.completeAuthorization(callback: Self.callback("\(prefix)state=\(request.pending.state)"), pending: request.pending)
    }
    #expect(transport.requests.isEmpty)
  }

  @Test("should never show the state or verifier of a pending authorization")
  func redactsPendingAuthorization() throws {
    let (_, request) = try Self.begin()
    var dumped = ""
    dump(request.pending, to: &dumped)

    for text in [String(describing: request.pending), String(reflecting: request.pending), dumped] {
      #expect(!text.contains(request.pending.state))
      #expect(!text.contains(request.pending.pkce.verifier))
    }
  }
}

@Suite("OAuthClientConfiguration", TestTimeLimit.quick)
struct OAuthClientConfigurationTests {
  private static func make(
    authorization: String = "https://login.example.com/authorize",
    token: String = "https://login.example.com/token",
    clientID: String = "client",
    redirect: String = "com.example.app:/callback",
    scopes: [String] = ["read"],
    parameters: [String: String] = [:]
  ) throws -> OAuthClientConfiguration {
    try OAuthClientConfiguration(
      authorizationEndpoint: #require(URL(string: authorization)),
      tokenEndpoint: #require(URL(string: token)),
      clientID: clientID,
      redirectURI: #require(URL(string: redirect)),
      scopes: scopes,
      additionalAuthorizationParameters: parameters
    )
  }

  @Test(
    "should accept https, loopback http and reverse-domain private-use redirects",
    arguments: ["https://app.example.com/callback", "http://127.0.0.1:8123/callback", "http://[::1]/cb", "http://localhost/cb", "msauth.com.example.app://auth"]
  )
  func acceptsRedirects(redirect: String) throws {
    _ = try Self.make(redirect: redirect)
  }

  @Test(
    "should refuse a redirect that is plain http, a bare scheme, or carries a query, fragment or credentials",
    arguments: ["http://example.com/cb", "myapp://callback", "com.example.app:/cb?x=1", "com.example.app:/cb#frag", "https://user:pass@example.com/cb"]
  )
  func refusesRedirects(redirect: String) {
    #expect(throws: OAuthError.self) { try Self.make(redirect: redirect) }
  }

  @Test("should refuse endpoints that are not https", arguments: ["http://login.example.com/authorize", "https://login.example.com/authorize#x"])
  func refusesEndpoints(endpoint: String) {
    #expect(throws: OAuthError.self) { try Self.make(authorization: endpoint) }
    #expect(throws: OAuthError.self) { try Self.make(token: endpoint) }
  }

  @Test("should refuse an empty or non-ASCII client id", arguments: ["", "clïent", "client\n"])
  func refusesClientIDs(clientID: String) {
    #expect(throws: OAuthError.self) { try Self.make(clientID: clientID) }
  }

  @Test("should refuse scopes with spaces, quotes or backslashes, empty scopes and duplicates", arguments: [["a b"], ["a\"b"], ["a\\b"], [""], ["a", "a"]])
  func refusesScopes(scopes: [String]) {
    #expect(throws: OAuthError.self) { try Self.make(scopes: scopes) }
  }

  @Test("should refuse extra parameters that the request sets itself or the endpoint already carries")
  func refusesParameterCollisions() {
    for name in ["state", "client_id", "code_challenge", "scope", ""] {
      #expect(throws: OAuthError.self) { try Self.make(parameters: [name: "x"]) }
    }
    #expect(throws: OAuthError.self) { try Self.make(authorization: "https://login.example.com/authorize?tenant=a", parameters: ["tenant": "b"]) }
    #expect(throws: OAuthError.self) { try Self.make(authorization: "https://login.example.com/authorize?state=fixed") }
  }
}
