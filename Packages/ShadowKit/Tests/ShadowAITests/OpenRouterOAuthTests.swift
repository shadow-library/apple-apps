import CryptoKit
import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("OpenRouterOAuth", .timeLimit(.minutes(1)))
struct OpenRouterOAuthTests {
  private static let registered = OpenRouterOAuth(configuration: OpenRouterConfiguration(callbackSchemes: ["ShadowLibrary"]), transport: StubHTTPTransport(json: "{}"))
  private static let rfc7636Verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  private static let rfc7636Challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  private static func independentChallenge(_ verifier: String) -> String {
    let digest = Array(SHA256.hash(data: Array(verifier.utf8)))
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    var bits = 0
    var buffer = 0
    var output = ""
    for byte in digest {
      buffer = (buffer << 8) | Int(byte)
      bits += 8
      while bits >= 6 {
        bits -= 6
        output.append(alphabet[(buffer >> bits) & 0x3F])
      }
    }
    if bits > 0 { output.append(alphabet[(buffer << (6 - bits)) & 0x3F]) }
    return output
  }

  private static func queryItems(_ url: URL) throws -> [String: String] {
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
  }

  @Test("should derive the RFC 7636 challenge from its verifier")
  func matchesRFCVector() throws {
    let challenge = try #require(OpenRouterOAuth.Challenge(verifier: Self.rfc7636Verifier))

    #expect(challenge.challenge == Self.rfc7636Challenge)
    #expect(challenge.method == "S256")
  }

  @Test("should make a fresh 256-bit verifier whose challenge is its SHA-256 in base64url")
  func makesChallenge() {
    let first = OpenRouterOAuth.makeChallenge()
    let second = OpenRouterOAuth.makeChallenge()
    let urlSafe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    #expect(first.verifier.count == 43)
    #expect(first.verifier.allSatisfy(urlSafe.contains))
    #expect(first.challenge == Self.independentChallenge(first.verifier))
    #expect(first.method == "S256")
    #expect(first.verifier != second.verifier)
  }

  @Test("should restore a challenge from its stored verifier")
  func restoresChallenge() throws {
    let original = OpenRouterOAuth.makeChallenge()

    let restored = try #require(OpenRouterOAuth.Challenge(verifier: original.verifier))

    #expect(restored.challenge == original.challenge)
    #expect(restored.method == original.method)
    #expect(restored.verifier == original.verifier)
  }

  @Test(
    "should accept a verifier of 43 to 128 unreserved characters",
    arguments: [String(repeating: "a", count: 43), String(repeating: "Z9-._~", count: 21) + "xy", String(repeating: "0", count: 128)]
  )
  func acceptsVerifiers(verifier: String) {
    #expect(OpenRouterOAuth.Challenge(verifier: verifier) != nil)
  }

  @Test(
    "should refuse a verifier of the wrong length or with reserved characters",
    arguments: [
      "", String(repeating: "a", count: 42), String(repeating: "a", count: 129), String(repeating: "a", count: 42) + "+", String(repeating: "a", count: 42) + "/",
      String(repeating: "a", count: 42) + "=", String(repeating: "a", count: 42) + " ", String(repeating: "a", count: 42) + "é",
    ]
  )
  func refusesVerifiers(verifier: String) {
    #expect(OpenRouterOAuth.Challenge(verifier: verifier) == nil)
  }

  @Test("should never print the verifier of a restored challenge")
  func redactsRestoredVerifier() throws {
    let restored = try #require(OpenRouterOAuth.Challenge(verifier: Self.rfc7636Verifier))
    var dumped = ""
    dump(restored, to: &dumped)

    for text in [String(describing: restored), String(reflecting: restored), dumped] { #expect(!text.contains(Self.rfc7636Verifier)) }
  }

  @Test("should never print its verifier")
  func redactsVerifier() {
    let challenge = OpenRouterOAuth.makeChallenge()
    var dumped = ""
    dump(challenge, to: &dumped)

    for text in [String(describing: challenge), String(reflecting: challenge), "\(challenge)", dumped] {
      #expect(!text.contains(challenge.verifier))
      #expect(text.contains("<redacted>"))
    }
  }

  @Test("should build the documented authorization URL with the callback encoded whole")
  func buildsAuthorizationURL() throws {
    let oauth = Self.registered
    let callback = try #require(URL(string: "shadowlibrary://oauth/openrouter?from=settings&x=a+b"))
    let challenge = try #require(OpenRouterOAuth.Challenge(verifier: Self.rfc7636Verifier))

    let url = try oauth.authorizationURL(callback: callback, challenge: challenge)

    #expect(url.scheme == "https")
    #expect(url.host() == "openrouter.ai")
    #expect(url.path() == "/auth")
    #expect(
      try Self.queryItems(url) == [
        "callback_url": "shadowlibrary://oauth/openrouter?from=settings&x=a+b", "code_challenge": Self.rfc7636Challenge, "code_challenge_method": "S256",
      ]
    )
    #expect(!url.absoluteString.contains(Self.rfc7636Verifier))
  }

  @Test(
    "should accept https, loopback http and a registered app scheme, whatever its case",
    arguments: ["https://app.example/cb", "http://localhost:51423/callback", "http://127.0.0.1/cb", "http://[::1]:8080/cb", "shadowlibrary://oauth", "SHADOWLIBRARY://oauth"]
  )
  func acceptsCallbacks(callback: String) throws {
    _ = try Self.registered.authorizationURL(callback: try #require(URL(string: callback)), challenge: OpenRouterOAuth.makeChallenge())
  }

  @Test(
    "should refuse any callback that is not https, loopback http or a registered app scheme",
    arguments: [
      "http://app.example/cb", "file:///tmp/cb", "javascript:alert(1)", "data:text/html,x", "https://user:pass@app.example/cb", "/relative",
      "otherapp://oauth", "mailto:someone@example.com", "tel:+15555550100", "vbscript:msgbox", "ssh://host.example", "https:///no-host",
    ]
  )
  func refusesCallbacks(callback: String) throws {
    let url = try #require(URL(string: callback))

    #expect(throws: ModelError.invalidRequest("The sign-in callback must be https, a loopback address or a registered app scheme.")) {
      try Self.registered.authorizationURL(callback: url, challenge: OpenRouterOAuth.makeChallenge())
    }
  }

  @Test("should refuse an app scheme when none is registered")
  func refusesUnregisteredScheme() throws {
    let oauth = OpenRouterOAuth(transport: StubHTTPTransport(json: "{}"))
    let url = try #require(URL(string: "shadowlibrary://oauth"))

    #expect(throws: ModelError.invalidRequest("The sign-in callback must be https, a loopback address or a registered app scheme.")) {
      try oauth.authorizationURL(callback: url, challenge: OpenRouterOAuth.makeChallenge())
    }
  }

  @Test("should exchange the code and verifier at the documented endpoint for the user's key")
  func exchangesCode() async throws {
    let plain = StubHTTPTransport(json: #"{"key":"sk-or-v1-user","user_id":"user_1"}"#)
    let oauth = OpenRouterOAuth(transport: plain)
    let challenge = try #require(OpenRouterOAuth.Challenge(verifier: Self.rfc7636Verifier))

    let key = try await oauth.exchange(code: "auth_code_abc123", challenge: challenge)

    #expect(key == "sk-or-v1-user")
    let sent = try #require(plain.requests.first)
    #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(
      try OpenRouterFixtures.json(sent.httpBody) == ["code": "auth_code_abc123", "code_verifier": .string(Self.rfc7636Verifier), "code_challenge_method": "S256"]
    )
  }

  @Test(
    "should map a failed exchange",
    arguments: [
      (403, OpenRouterFixtures.errorBody(code: 403, message: "Invalid code or code_verifier"), ModelError.forbidden("Invalid code or code_verifier")),
      (403, OpenRouterFixtures.errorBody(code: 403, message: "Authorization code expired"), .forbidden("Authorization code expired")),
      (400, OpenRouterFixtures.errorBody(code: 400, message: "Invalid code_challenge_method"), .invalidRequest("Invalid code_challenge_method")),
      (500, "", .server(status: 500)), (200, #"{"user_id":"user_1"}"#, .malformedResponse("The sign-in exchange returned no key.")),
      (200, #"{"key":"  "}"#, .malformedResponse("The sign-in exchange returned no key.")),
    ]
  )
  func mapsExchangeFailures(status: Int, body: String, expected: ModelError) async throws {
    let oauth = OpenRouterOAuth(transport: StubHTTPTransport(statusCode: status, json: body))

    await #expect(throws: expected) { try await oauth.exchange(code: "auth_code_abc123", challenge: OpenRouterOAuth.makeChallenge()) }
  }

  @Test("should refuse an empty code without sending anything")
  func refusesEmptyCode() async throws {
    let plain = StubHTTPTransport(json: "{}")

    await #expect(throws: ModelError.invalidRequest("The sign-in returned no code.")) {
      try await OpenRouterOAuth(transport: plain).exchange(code: "  ", challenge: OpenRouterOAuth.makeChallenge())
    }
    #expect(plain.requests.isEmpty)
  }

  @Test("should refuse to exchange over a plain-http remote origin")
  func refusesInsecureOrigin() async throws {
    let plain = StubHTTPTransport(json: "{}")
    let origin = try #require(URL(string: "http://openrouter.example"))

    await #expect(throws: ModelError.invalidRequest("The sign-in origin must be https.")) {
      try await OpenRouterOAuth(configuration: OpenRouterConfiguration(origin: origin), transport: plain).exchange(code: "c", challenge: OpenRouterOAuth.makeChallenge())
    }
    #expect(plain.requests.isEmpty)
  }

  @Test(
    "should refuse a lookalike of a loopback host",
    arguments: [
      "http://localhost.evil.example", "http://localhost.evil.example:8080/cb", "http://127.0.0.1.evil.example/cb", "http://evil-localhost/cb", "http://localhost@evil.example/cb",
      "http://127.0.0.1@evil.example/cb", "http://127.0.0.2/cb", "http://0.0.0.0/cb", "http://[::2]/cb",
    ]
  )
  func refusesLookalikeHosts(callback: String) throws {
    let url = try #require(URL(string: callback))

    #expect(throws: ModelError.invalidRequest("The sign-in callback must be https, a loopback address or a registered app scheme.")) {
      try Self.registered.authorizationURL(callback: url, challenge: OpenRouterOAuth.makeChallenge())
    }
  }

  @Test("should refuse the long-hand form of the IPv6 loopback address, which it does not recognise")
  func refusesLongHandLoopback() throws {
    let url = try #require(URL(string: "http://[0:0:0:0:0:0:0:1]/cb"))

    #expect(!OpenRouterOAuth.isLoopback(url))
    #expect(throws: ModelError.invalidRequest("The sign-in callback must be https, a loopback address or a registered app scheme.")) {
      try Self.registered.authorizationURL(callback: url, challenge: OpenRouterOAuth.makeChallenge())
    }
  }
}
