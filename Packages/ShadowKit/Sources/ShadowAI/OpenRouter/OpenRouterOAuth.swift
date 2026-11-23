import CryptoKit
import Foundation
import ShadowNetworking

public struct OpenRouterOAuth: Sendable {
  public struct Challenge: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let verifier: String
    public let challenge: String
    public let method: String

    public var description: String { "OpenRouterOAuth.Challenge(challenge: \(challenge), method: \(method), verifier: <redacted>)" }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: ["challenge": challenge, "method": method, "verifier": "<redacted>"], displayStyle: .struct) }

    public init?(verifier: String) {
      guard OpenRouterOAuth.verifierLengths.contains(verifier.utf8.count), verifier.utf8.allSatisfy(OpenRouterOAuth.isUnreserved) else { return nil }
      self.init(validVerifier: verifier)
    }

    fileprivate init(validVerifier verifier: String) {
      self.verifier = verifier
      challenge = OpenRouterOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
      method = OpenRouterOAuth.challengeMethod
    }
  }

  private struct ExchangeBody: Encodable {
    let code: String
    let codeVerifier: String
    let codeChallengeMethod: String

    enum CodingKeys: String, CodingKey {
      case code
      case codeVerifier = "code_verifier"
      case codeChallengeMethod = "code_challenge_method"
    }
  }

  private struct ExchangeResult: Decodable {
    let key: String
  }

  static let challengeMethod = "S256"
  private static let verifierByteCount = 32
  private static let verifierLengths = 43...128
  private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
  private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  private let configuration: OpenRouterConfiguration
  private let transport: any HTTPTransport

  public init(configuration: OpenRouterConfiguration = .init(), transport: any HTTPTransport) {
    self.configuration = configuration
    self.transport = transport
  }

  public static func makeChallenge() -> Challenge {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<verifierByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Challenge(validVerifier: base64URL(Data(bytes)))
  }

  /// A fresh value for the documented `state` parameter, which OpenRouter returns unchanged with the code.
  public static func makeState() -> String {
    var generator = SystemRandomNumberGenerator()
    return base64URL(Data((0..<verifierByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }

  public func authorizationURL(callback: URL, challenge: Challenge, state: String? = nil) throws(ModelError) -> URL {
    guard isAcceptableCallback(callback) else { throw .invalidRequest("The sign-in callback must be https, a loopback address or a registered app scheme.") }
    guard configuration.hasSecureOrigin, var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false) else {
      throw .invalidRequest("The sign-in origin must be https.")
    }
    components.percentEncodedQueryItems =
      [
        URLQueryItem(name: "callback_url", value: Self.percentEncoded(callback.absoluteString)),
        URLQueryItem(name: "code_challenge", value: Self.percentEncoded(challenge.challenge)),
        URLQueryItem(name: "code_challenge_method", value: Self.percentEncoded(challenge.method)),
      ] + [state].compactMap { $0 }.map { URLQueryItem(name: "state", value: Self.percentEncoded($0)) }
    guard let url = components.url else { throw .invalidRequest("The sign-in address could not be built.") }
    return url
  }

  /// The authorization code OpenRouter returns to `callback` as its one `code` query item, with the `state` it was sent, if any; a return to any other
  /// address carries none.
  public static func code(returnedTo url: URL, callback: URL, state: String? = nil) throws(ModelError) -> String {
    guard url.scheme?.lowercased() == callback.scheme?.lowercased(), url.host()?.lowercased() == callback.host()?.lowercased(),
      normalizedPath(url) == normalizedPath(callback)
    else { throw .malformedResponse("The sign-in returned to an unexpected address.") }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    if let state, items.filter({ $0.name == "state" }).map(\.value) != [state] { throw .malformedResponse("The sign-in returned another state.") }
    let codes = items.filter { $0.name == "code" }
    guard codes.count == 1, let code = codes[0].value?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
      throw .malformedResponse("The sign-in returned no code.")
    }
    return code
  }

  private static func normalizedPath(_ url: URL) -> String {
    let path = url.path(percentEncoded: true)
    return path.isEmpty ? "/" : path
  }

  public func exchange(code: String, challenge: Challenge) async throws(ModelError) -> String {
    let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else { throw .invalidRequest("The sign-in returned no code.") }
    guard configuration.hasSecureOrigin else { throw .invalidRequest("The sign-in origin must be https.") }
    var request = URLRequest(url: configuration.authKeysURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      request.httpBody = try JSONEncoder().encode(ExchangeBody(code: code, codeVerifier: challenge.verifier, codeChallengeMethod: challenge.method))
    } catch {
      throw .invalidRequest("The sign-in exchange could not be encoded.")
    }
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch {
      throw ModelError(converting: error)
    }
    guard (200..<300).contains(response.statusCode) else { throw OpenRouterFailure.response(response, body: data, secret: challenge.verifier) }
    guard let key = try? JSONDecoder().decode(ExchangeResult.self, from: data).key.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
      throw .malformedResponse("The sign-in exchange returned no key.")
    }
    return key
  }

  static func isLoopback(_ url: URL) -> Bool {
    guard var host = url.host(percentEncoded: false)?.lowercased() else { return false }
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    return loopbackHosts.contains(host)
  }

  private func isAcceptableCallback(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty, url.user() == nil, url.password() == nil else { return false }
    switch scheme {
    case "https": return url.host() != nil
    case "http": return Self.isLoopback(url)
    default: return configuration.callbackSchemes.contains { $0.lowercased() == scheme }
    }
  }

  private static func isUnreserved(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
    case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"): true
    default: false
    }
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  private static func percentEncoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }
}
