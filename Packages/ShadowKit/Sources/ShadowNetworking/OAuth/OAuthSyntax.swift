import Foundation

enum OAuthSyntax {
  private static let providerTextLimit = 512
  static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
  private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func isUnreserved(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
    case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"): true
    default: false
    }
  }

  static func isScopeToken(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { $0 == 0x21 || (0x23...0x5B).contains($0) || (0x5D...0x7E).contains($0) }
  }

  static func isVisibleASCII(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (0x20...0x7E).contains($0) }
  }

  static func percentEncoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  static func formEncoded(_ pairs: [(String, String)]) -> Data {
    Data(pairs.map { "\(percentEncoded($0.0))=\(percentEncoded($0.1))" }.joined(separator: "&").utf8)
  }

  static func normalizedHost(_ url: URL) -> String? {
    guard var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    return host
  }

  static func isLoopback(_ url: URL) -> Bool {
    normalizedHost(url).map(loopbackHosts.contains) ?? false
  }

  static func isSameRedirect(_ callback: URL, _ redirect: URL) -> Bool {
    guard callback.scheme?.lowercased() == redirect.scheme?.lowercased() else { return false }
    guard normalizedHost(callback) == normalizedHost(redirect), callback.port == redirect.port else { return false }
    guard callback.user() == nil, callback.password() == nil else { return false }
    return callback.path(percentEncoded: true) == redirect.path(percentEncoded: true)
  }

  static func providerText(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(providerTextLimit)))
  }

  static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
