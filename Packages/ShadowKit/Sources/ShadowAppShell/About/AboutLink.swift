import Foundation

/// A way out of the About screen to the app's pages or its owner: shown only for what the app's identity sets, opened by the system.
public nonisolated enum AboutLink: Hashable, Sendable, Identifiable {
  case privacyPolicy(URL)
  case support(URL)
  case contact(URL)

  public var id: String {
    switch self {
    case .privacyPolicy: "privacy-policy"
    case .support: "support"
    case .contact: "contact"
    }
  }

  public var url: URL {
    switch self {
    case .privacyPolicy(let url), .support(let url), .contact(let url): url
    }
  }

  /// The links in the order the screen shows them. A page must be `https` and an address a single mailbox, or its row is left out.
  public static func links(for app: AppIdentity, version: AppVersion) -> [AboutLink] {
    [
      app.privacyPolicyURL.flatMap(webPage).map(AboutLink.privacyPolicy),
      app.supportURL.flatMap(webPage).map(AboutLink.support),
      app.contactAddress.flatMap { mailto($0, subject: "\(app.displayName) \(version.text)") }.map(AboutLink.contact),
    ]
    .compactMap(\.self)
  }

  public static func mailto(_ address: String, subject: String) -> URL? {
    guard isMailbox(address) else { return nil }
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = address
    components.queryItems = [URLQueryItem(name: "subject", value: subject)]
    return components.url
  }

  private static func webPage(_ url: URL) -> URL? {
    guard url.scheme?.lowercased() == "https", url.host()?.isEmpty == false else { return nil }
    return url
  }

  private static func isMailbox(_ address: String) -> Bool {
    let parts = address.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, let local = parts.first, let domain = parts.last, !local.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else {
      return false
    }
    return address.unicodeScalars.allSatisfy(mailboxCharacters.contains)
  }

  private static let mailboxCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.!#$'*+-=^_`{|}~"))
}
