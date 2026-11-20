import CryptoKit
import Foundation

public struct OAuthRandomSource: Sendable {
  public static let system = OAuthRandomSource { count in
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  private let generate: @Sendable (Int) -> [UInt8]

  public init(bytes: @escaping @Sendable (Int) -> [UInt8]) {
    generate = bytes
  }

  func bytes(_ count: Int) -> [UInt8] {
    let bytes = generate(count)
    precondition(bytes.count == count, "An OAuth random source returned \(bytes.count) bytes where \(count) were asked for.")
    return bytes
  }

  func token(byteCount: Int) -> String {
    Data(bytes(byteCount)).base64URLEncodedString()
  }
}

public struct OAuthPKCE: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public static let method = "S256"
  static let verifierByteCount = 32
  private static let verifierLengths = 43...128

  public let verifier: String
  public let challenge: String

  public var description: String { "OAuthPKCE(challenge: \(challenge), method: \(Self.method), verifier: <redacted>)" }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, children: ["challenge": challenge, "method": Self.method, "verifier": "<redacted>"], displayStyle: .struct) }

  public init?(verifier: String) {
    guard Self.verifierLengths.contains(verifier.utf8.count), verifier.utf8.allSatisfy(OAuthSyntax.isUnreserved) else { return nil }
    self.init(validVerifier: verifier)
  }

  private init(validVerifier verifier: String) {
    self.verifier = verifier
    challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
  }

  public static func generate(using random: OAuthRandomSource = .system) -> OAuthPKCE {
    OAuthPKCE(validVerifier: random.token(byteCount: verifierByteCount))
  }
}

extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
