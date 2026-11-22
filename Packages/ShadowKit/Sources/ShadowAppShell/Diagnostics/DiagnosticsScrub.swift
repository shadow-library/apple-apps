import Foundation

/// The last pass over every file of a diagnostics archive. Nothing should reach it that names the owner or opens their accounts; it replaces what still
/// looks like a bearer token, an API key, an access key id, a long secret, an email address or a home folder's name.
nonisolated enum DiagnosticsScrub {
  static let redacted = "<redacted>"

  static func apply(_ text: String) -> String {
    var text = text
    text.replace(#/(?i)\bbearer\s+[A-Za-z0-9._~+\/=-]+/#) { _ in "Bearer \(redacted)" }
    text.replace(#/\bsk-[A-Za-z0-9_-]{8,}/#) { _ in redacted }
    text.replace(#/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/#) { _ in redacted }
    text.replace(#/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/#) { _ in redacted }
    text.replace(#/\/Users\/[^\/\s"]+/#) { _ in "/Users/\(redacted)" }
    text.replace(#/[A-Za-z0-9+\/_=]{32,}/#) { match in isSecretLike(match.output) ? redacted : String(match.output) }
    return text
  }

  /// A long run of letters and digits, like a key or token; a run of letters alone, such as a long identifier, stays.
  private static func isSecretLike(_ run: Substring) -> Bool {
    run.contains(where: \.isNumber) && run.contains(where: \.isLetter)
  }
}
