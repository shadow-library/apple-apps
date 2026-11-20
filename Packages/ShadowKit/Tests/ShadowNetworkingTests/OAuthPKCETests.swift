import Foundation
import ShadowNetworking
import Testing

@Suite("OAuthPKCE", TestTimeLimit.quick)
struct OAuthPKCETests {
  private static let rfc7636Verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  private static let rfc7636Challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  private static let rfc7636VerifierBytes: [UInt8] = [
    116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121,
  ]

  @Test("should derive the RFC 7636 appendix B challenge from its verifier")
  func matchesRFCVector() throws {
    let pkce = try #require(OAuthPKCE(verifier: Self.rfc7636Verifier))

    #expect(pkce.challenge == Self.rfc7636Challenge)
    #expect(OAuthPKCE.method == "S256")
  }

  @Test("should encode the random octets of RFC 7636 appendix B into its verifier")
  func generatesFromRandomSource() {
    let pkce = OAuthPKCE.generate(using: OAuthRandomSource { count in Array(Self.rfc7636VerifierBytes.prefix(count)) })

    #expect(pkce.verifier == Self.rfc7636Verifier)
    #expect(pkce.challenge == Self.rfc7636Challenge)
  }

  @Test("should make a different 43-character verifier on every system draw")
  func generatesFreshVerifiers() {
    let first = OAuthPKCE.generate()
    let second = OAuthPKCE.generate()

    #expect(first.verifier.count == 43)
    #expect(OAuthPKCE(verifier: first.verifier)?.challenge == first.challenge)
    #expect(first.verifier != second.verifier)
  }

  @Test(
    "should accept a verifier of 43 to 128 unreserved characters",
    arguments: [String(repeating: "a", count: 43), String(repeating: "Z9-._~", count: 21) + "xy", String(repeating: "0", count: 128)]
  )
  func acceptsVerifiers(verifier: String) {
    #expect(OAuthPKCE(verifier: verifier) != nil)
  }

  @Test(
    "should refuse a verifier of the wrong length or with reserved characters",
    arguments: [
      "", String(repeating: "a", count: 42), String(repeating: "a", count: 129), String(repeating: "a", count: 42) + "+",
      String(repeating: "a", count: 42) + "/", String(repeating: "a", count: 42) + "=", String(repeating: "a", count: 42) + "é",
    ]
  )
  func refusesVerifiers(verifier: String) {
    #expect(OAuthPKCE(verifier: verifier) == nil)
  }

  @Test("should never show the verifier in a description, debug description or mirror")
  func redactsVerifier() {
    let pkce = OAuthPKCE.generate()
    var dumped = ""
    dump(pkce, to: &dumped)

    for text in [String(describing: pkce), String(reflecting: pkce), dumped] {
      #expect(!text.contains(pkce.verifier))
      #expect(text.contains(pkce.challenge))
    }
  }
}
