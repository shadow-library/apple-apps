import Foundation

public struct AnthropicConfiguration: Sendable, Equatable {
  public static let defaultOrigin: URL = {
    guard let origin = URL(string: "https://api.anthropic.com") else { preconditionFailure("The Anthropic origin is a valid URL.") }
    return origin
  }()

  public static let defaultAPIVersion = "2026-10-21"
  public static let defaultIdleTimeout = Duration.seconds(300)
  static let lookupTimeout = Duration.seconds(30)

  public var origin: URL
  public var apiVersion: String
  /// How long a streamed reply may stay silent; with reasoning text hidden, a long think sends nothing.
  public var idleTimeout: Duration

  public init(origin: URL = Self.defaultOrigin, apiVersion: String = Self.defaultAPIVersion, idleTimeout: Duration = Self.defaultIdleTimeout) {
    self.origin = origin
    self.apiVersion = apiVersion
    self.idleTimeout = idleTimeout
  }

  var messagesURL: URL { origin.appending(path: "v1/messages") }

  func modelsURL(limit: Int, after cursor: String?) -> URL {
    var items = [URLQueryItem(name: "limit", value: String(limit))]
    if let cursor { items.append(URLQueryItem(name: "after_id", value: cursor)) }
    return origin.appending(path: "v1/models").appending(queryItems: items)
  }
}
