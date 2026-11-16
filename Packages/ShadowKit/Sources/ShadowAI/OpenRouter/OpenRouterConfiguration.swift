import Foundation

public struct OpenRouterConfiguration: Sendable, Equatable {
  public static let defaultOrigin: URL = {
    guard let url = URL(string: "https://openrouter.ai") else { preconditionFailure("The OpenRouter origin literal is not a URL.") }
    return url
  }()

  public var origin: URL
  public var applicationTitle: String?
  /// OpenRouter attributes usage to an app only when `HTTP-Referer` is sent.
  public var applicationURL: URL?
  public var callbackSchemes: Set<String>

  public init(
    origin: URL = OpenRouterConfiguration.defaultOrigin,
    applicationTitle: String? = nil,
    applicationURL: URL? = nil,
    callbackSchemes: Set<String> = []
  ) {
    self.origin = origin
    self.applicationTitle = applicationTitle
    self.applicationURL = applicationURL
    self.callbackSchemes = callbackSchemes
  }

  var chatCompletionsURL: URL { apiURL("chat/completions") }

  var keyURL: URL { apiURL("key") }

  var modelsURL: URL { apiURL("models") }

  var authKeysURL: URL { apiURL("auth/keys") }

  var authorizationURL: URL { origin.appending(path: "auth") }

  var attributionHeaders: [String: String] {
    var headers: [String: String] = [:]
    if let referer = applicationURL?.absoluteString, Self.isHeaderSafe(referer) { headers["HTTP-Referer"] = referer }
    if let title = applicationTitle?.trimmingCharacters(in: .whitespaces), Self.isHeaderSafe(title) { headers["X-OpenRouter-Title"] = title }
    return headers
  }

  var hasSecureOrigin: Bool {
    switch origin.scheme?.lowercased() {
    case "https": origin.host() != nil
    case "http": OpenRouterOAuth.isLoopback(origin)
    default: false
    }
  }

  private func apiURL(_ path: String) -> URL {
    origin.appending(path: "api/v1").appending(path: path)
  }

  private static func isHeaderSafe(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (0x20...0x7E).contains($0) }
  }
}
