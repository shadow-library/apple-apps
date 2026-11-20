import Foundation
import ShadowSync
import ShadowSyncS3
import Testing

enum S3Fixture {
  static func provider(
    _ fake: FakeS3Service,
    keyPrefix: String = "",
    conditionalWrites: Bool? = nil,
    secretAccessKey: String? = nil,
    clockOffset: TimeInterval = 0,
    insecureLocalhost: Bool = false,
    endpoint: String? = nil
  ) throws -> S3StorageProvider {
    let options = fake.options
    let scheme = insecureLocalhost ? "http" : "https"
    let configuration = try S3Configuration(
      endpoint: #require(URL(string: endpoint ?? "\(scheme)://\(options.endpointHost)")),
      region: options.region,
      bucket: options.bucket,
      keyPrefix: keyPrefix,
      addressingStyle: options.style,
      supportsConditionalWrites: conditionalWrites ?? options.honorsConditionalWrites,
      allowsInsecureLocalhost: insecureLocalhost
    )
    let credentials = try S3Credentials(
      accessKeyID: options.accessKeyID, secretAccessKey: secretAccessKey ?? options.secretAccessKey, sessionToken: options.sessionToken)
    let now = options.serverDate.addingTimeInterval(clockOffset)
    return S3StorageProvider(configuration: configuration, credentials: credentials, transport: fake, now: { now })
  }

  static func key(_ raw: String) throws -> ObjectKey {
    try #require(ObjectKey(raw))
  }

  static func failure<T>(_ body: () async throws -> T) async -> StorageError? {
    do {
      _ = try await body()
      return nil
    } catch let error as StorageError {
      return error
    } catch {
      Issue.record("Expected a StorageError, got \(error)")
      return nil
    }
  }
}
