import Foundation
import Testing

@testable import ShadowAI

@Suite("ProviderCredential")
struct ProviderCredentialTests {
  private static let secret = "sk-ant-api03-SECRETVALUE"

  private static func credential(_ origin: String, secret: String = secret) -> ProviderCredential? {
    URL(string: origin).flatMap { ProviderCredential(origin: $0, secret: secret) }
  }

  @Test(
    "should accept https origins and loopback http",
    arguments: [
      "https://api.anthropic.com", "https://api.anthropic.com/", "https://gateway.example:8443", "HTTPS://API.Example.com", "http://localhost:8080",
      "http://127.0.0.1:11434", "http://[::1]:8080",
    ]
  )
  func acceptsOrigins(origin: String) {
    #expect(Self.credential(origin) != nil)
  }

  @Test(
    "should reject origins that are not bare https",
    arguments: [
      "http://api.anthropic.com", "ftp://api.anthropic.com", "https://api.anthropic.com/v1", "https://api.anthropic.com/?key=1", "https://api.anthropic.com/#top",
      "https://user:pass@api.anthropic.com", "https://user@api.anthropic.com", "http://localhost.evil.example", "file:///tmp/key",
    ]
  )
  func rejectsOrigins(origin: String) {
    #expect(Self.credential(origin) == nil)
  }

  @Test("should reject an empty secret or one with control characters", arguments: ["", "   ", "\n", "sk-one\r\nX-Injected: 1", "sk\u{0}x"])
  func rejectsSecrets(secret: String) {
    #expect(Self.credential("https://api.anthropic.com", secret: secret) == nil)
  }

  @Test("should trim whitespace around a pasted secret")
  func trimsSecret() {
    #expect(Self.credential("https://api.anthropic.com", secret: "  sk-key\n")?.secret == "sk-key")
  }

  @Test(
    "should authorize only the same scheme, host and port",
    arguments: [
      ("https://api.anthropic.com/v1/messages", true),
      ("https://api.anthropic.com:443/v1/models", true),
      ("https://API.ANTHROPIC.COM/v1/messages", true),
      ("HTTPS://api.anthropic.com/v1/messages?beta=true", true),
      ("http://api.anthropic.com/v1/messages", false),
      ("https://api.anthropic.com:8443/v1/messages", false),
      ("https://evil.example/v1/messages", false),
      ("https://api.anthropic.com.evil.example/v1/messages", false),
      ("https://api.anthropic.com@evil.example/v1/messages", false),
      ("https://user@api.anthropic.com/v1/messages", false),
      ("https://api.anthropic.com./v1/messages", false),
      ("wss://api.anthropic.com/v1/messages", false),
    ]
  )
  func authorizesSameOrigin(target: String, expected: Bool) throws {
    let credential = try #require(Self.credential("https://api.anthropic.com"))
    #expect(credential.authorizes(try #require(URL(string: target))) == expected)
  }

  @Test("should match an upper-case origin and an explicit default port")
  func normalizesOrigin() throws {
    let credential = try #require(Self.credential("HTTPS://Gateway.Example:443/"))
    #expect(credential.authorizes(try #require(URL(string: "https://gateway.example/v1/messages"))))
  }

  @Test("should authorize loopback only on its own port")
  func authorizesLoopback() throws {
    let credential = try #require(Self.credential("http://localhost:8080"))
    #expect(credential.authorizes(try #require(URL(string: "http://localhost:8080/v1/chat/completions"))))
    #expect(!credential.authorizes(try #require(URL(string: "http://localhost:9090/v1/chat/completions"))))
    #expect(!credential.authorizes(try #require(URL(string: "https://localhost:8080/v1/chat/completions"))))
  }

  @Test("should never print the secret")
  func redactsSecret() throws {
    let credential = try #require(Self.credential("https://api.anthropic.com"))
    var dumped = ""
    dump(credential, to: &dumped)
    let renderings = [
      String(describing: credential), String(reflecting: credential), "\(credential)", dumped, String(describing: [credential]), String(describing: Optional(credential)),
    ]
    for rendering in renderings {
      #expect(!rendering.contains("SECRETVALUE"))
      #expect(rendering.contains("api.anthropic.com"))
    }
  }
}
