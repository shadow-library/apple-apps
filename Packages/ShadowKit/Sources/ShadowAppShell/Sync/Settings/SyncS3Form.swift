import Foundation
import ShadowSyncRuntime
import ShadowSyncS3

nonisolated struct SyncS3Form: Equatable, Sendable {
  enum Field: Hashable, Sendable {
    case endpoint
    case region
    case bucket
    case keyPrefix
    case credentials
  }

  struct Issue: Error, Equatable, Sendable {
    let field: Field
    let message: String
  }

  struct Validated: Equatable, Sendable {
    let configuration: S3Configuration
    let credentials: S3Credentials
  }

  var endpoint = ""
  var region = ""
  var bucket = ""
  var keyPrefix = ""
  var addressing = S3Configuration.AddressingStyle.virtualHosted
  var accessKeyID = ""
  var secretAccessKey = ""

  init() {}

  /// For a location another device named: everything but the credentials, which stay in the keychain.
  init(_ settings: SyncS3Settings) {
    endpoint = settings.endpoint.absoluteString
    region = settings.region
    bucket = settings.bucket
    keyPrefix = settings.keyPrefix
    addressing = S3Configuration.AddressingStyle(rawValue: settings.addressingStyle) ?? .virtualHosted
  }

  var isComplete: Bool {
    [endpoint, region, bucket, accessKeyID, secretAccessKey].allSatisfy { !Self.trimmed($0).isEmpty }
  }

  func validate() -> Result<Validated, Issue> {
    let configuration: S3Configuration
    do {
      configuration = try makeConfiguration()
    } catch {
      return .failure(Self.issue(for: error))
    }
    let key = Self.trimmed(accessKeyID)
    let secret = Self.trimmed(secretAccessKey)
    guard !key.isEmpty, !secret.isEmpty else {
      return .failure(Issue(field: .credentials, message: String(localized: "Enter the access key ID and the secret access key.", table: "SyncSettings", bundle: .module)))
    }
    do {
      return .success(Validated(configuration: configuration, credentials: try S3Credentials(accessKeyID: key, secretAccessKey: secret)))
    } catch {
      return .failure(Self.issue(for: error))
    }
  }

  private func makeConfiguration() throws(S3ConfigurationError) -> S3Configuration {
    let typed = Self.trimmed(endpoint)
    guard !typed.isEmpty, let url = URL(string: typed.contains("://") ? typed : "https://" + typed) else { throw .invalidEndpoint("It is not an address.") }
    return try S3Configuration(
      endpoint: url, region: Self.trimmed(region), bucket: Self.trimmed(bucket), keyPrefix: Self.trimmed(keyPrefix).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
      addressingStyle: addressing, allowsInsecureLocalhost: url.scheme?.lowercased() == "http")
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func issue(for error: S3ConfigurationError) -> Issue {
    switch error {
    case .insecureEndpoint:
      Issue(
        field: .endpoint,
        message: String(localized: "The endpoint must start with https://. Plain http:// works only for this device's own address.", table: "SyncSettings", bundle: .module))
    case .invalidEndpoint:
      Issue(
        field: .endpoint,
        message: String(localized: "Enter the service's address, such as https://s3.eu-west-1.amazonaws.com, with no path.", table: "SyncSettings", bundle: .module))
    case .invalidRegion:
      Issue(
        field: .region, message: String(localized: "Enter the bucket's region in lowercase, such as eu-west-1. Some services use auto.", table: "SyncSettings", bundle: .module))
    case .invalidBucket:
      Issue(field: .bucket, message: String(localized: "Enter the bucket name: 3 to 63 lowercase letters, digits, dots or hyphens.", table: "SyncSettings", bundle: .module))
    case .dottedBucketNeedsPathStyle:
      Issue(field: .bucket, message: String(localized: "A bucket name with dots needs path-style addressing.", table: "SyncSettings", bundle: .module))
    case .invalidKeyPrefix:
      Issue(
        field: .keyPrefix,
        message: String(localized: "A folder in the bucket uses letters, digits, dots, hyphens and underscores, separated by slashes.", table: "SyncSettings", bundle: .module))
    case .invalidCredentials:
      Issue(field: .credentials, message: String(localized: "Keys are letters, digits and symbols with no spaces.", table: "SyncSettings", bundle: .module))
    }
  }
}
