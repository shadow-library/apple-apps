import Foundation

public struct ProviderCredential: Sendable {
  private struct Endpoint: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
      guard let scheme = url.scheme?.lowercased(), url.user() == nil, url.password() == nil else { return nil }
      guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
      if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
      switch (scheme, url.port) {
      case (_, let port?): self.port = port
      case ("https", nil): port = 443
      case ("http", nil): port = 80
      default: return nil
      }
      self.scheme = scheme
      self.host = host
    }
  }

  private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

  public let origin: URL
  public let secret: String
  private let endpoint: Endpoint

  /// Accepts an https origin (http only for a loopback host) with no path, query or fragment, and a secret without control characters; surrounding whitespace is trimmed.
  public init?(origin: URL, secret: String) {
    guard let endpoint = Endpoint(origin) else { return nil }
    switch endpoint.scheme {
    case "https": break
    case "http": guard Self.loopbackHosts.contains(endpoint.host) else { return nil }
    default: return nil
    }
    guard ["", "/"].contains(origin.path(percentEncoded: true)), origin.query(percentEncoded: true) == nil, origin.fragment(percentEncoded: true) == nil else { return nil }
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    self.origin = origin
    self.secret = trimmed
    self.endpoint = endpoint
  }

  /// True only for the origin's scheme, host and port. Adapters must check it before attaching the secret to any request.
  public func authorizes(_ url: URL) -> Bool {
    Endpoint(url) == endpoint
  }
}

extension ProviderCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String { "ProviderCredential(origin: \(origin.absoluteString), secret: <redacted>)" }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, children: ["origin": origin, "secret": "<redacted>"], displayStyle: .struct) }
}
