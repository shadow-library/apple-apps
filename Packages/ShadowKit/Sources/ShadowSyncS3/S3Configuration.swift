import Foundation
import ShadowSync

public struct S3Configuration: Sendable, Hashable {
  public enum AddressingStyle: String, Sendable, Hashable, CaseIterable {
    case virtualHosted
    case path
  }

  public static let maxKeyUTF8Length = 1024
  public static let maxKeyPrefixUTF8Length = maxKeyUTF8Length - ObjectKey.maxUTF8Length - 1
  private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

  public let endpoint: URL
  public let region: String
  public let bucket: String
  public let keyPrefix: String
  public let addressingStyle: AddressingStyle
  public let supportsConditionalWrites: Bool
  public let allowsInsecureLocalhost: Bool

  public init(
    endpoint: URL,
    region: String,
    bucket: String,
    keyPrefix: String = "",
    addressingStyle: AddressingStyle = .virtualHosted,
    supportsConditionalWrites: Bool = false,
    allowsInsecureLocalhost: Bool = false
  ) throws(S3ConfigurationError) {
    self.endpoint = try Self.validatedEndpoint(endpoint, allowsInsecureLocalhost: allowsInsecureLocalhost, addressingStyle: addressingStyle)
    guard Self.isValidRegion(region) else { throw .invalidRegion }
    guard Self.isValidBucket(bucket) else { throw .invalidBucket }
    guard addressingStyle == .path || !bucket.contains(".") else { throw .dottedBucketNeedsPathStyle }
    guard keyPrefix.isEmpty || (ObjectKey(keyPrefix) != nil && keyPrefix.utf8.count <= Self.maxKeyPrefixUTF8Length) else { throw .invalidKeyPrefix }
    self.region = region
    self.bucket = bucket
    self.keyPrefix = keyPrefix
    self.addressingStyle = addressingStyle
    self.supportsConditionalWrites = supportsConditionalWrites
    self.allowsInsecureLocalhost = allowsInsecureLocalhost
  }

  public func objectName(for key: ObjectKey) -> String {
    keyPrefix.isEmpty ? key.rawValue : "\(keyPrefix)/\(key.rawValue)"
  }

  private static func validatedEndpoint(_ url: URL, allowsInsecureLocalhost: Bool, addressingStyle: AddressingStyle) throws(S3ConfigurationError) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased() else {
      throw .invalidEndpoint("It is not an absolute URL.")
    }
    guard let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else {
      throw .invalidEndpoint("It has no host.")
    }
    switch scheme {
    case "https": break
    case "http": guard allowsInsecureLocalhost, loopbackHosts.contains(host) else { throw .insecureEndpoint }
    default: throw .invalidEndpoint("Its scheme must be https.")
    }
    guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
      throw .invalidEndpoint("It must carry no credentials, query or fragment.")
    }
    guard components.path.isEmpty || components.path == "/" else { throw .invalidEndpoint("It must have no path.") }
    guard addressingStyle == .path || !(loopbackHosts.contains(host) || isIPAddress(host)) else {
      throw .invalidEndpoint("Virtual-hosted addressing needs a DNS name; use path-style for an IP address or localhost.")
    }
    components.scheme = scheme
    components.path = ""
    guard let normalized = components.url else { throw .invalidEndpoint("It cannot be rebuilt.") }
    return normalized
  }

  private static func isValidRegion(_ region: String) -> Bool {
    (1...64).contains(region.utf8.count) && region.utf8.allSatisfy { isLowercaseAlphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
  }

  private static func isValidBucket(_ bucket: String) -> Bool {
    let bytes = Array(bucket.utf8)
    guard (3...63).contains(bytes.count), let first = bytes.first, let last = bytes.last, isLowercaseAlphanumeric(first), isLowercaseAlphanumeric(last) else { return false }
    guard bytes.allSatisfy({ isLowercaseAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }) else { return false }
    return !bucket.contains("..") && !isIPAddress(bucket)
  }

  private static func isIPAddress(_ host: String) -> Bool {
    if host.contains(":") { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.utf8.count <= 3 && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }
  }

  private static func isLowercaseAlphanumeric(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
  }
}
