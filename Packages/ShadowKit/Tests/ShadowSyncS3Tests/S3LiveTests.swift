import Foundation
import ShadowSync
import ShadowSyncS3
import ShadowTestSupport
import Testing

private enum LiveEnvironment {
  static let values = ProcessInfo.processInfo.environment

  static var isConfigured: Bool {
    ["ENDPOINT", "REGION", "BUCKET", "ACCESS_KEY_ID", "SECRET_ACCESS_KEY"].allSatisfy { values["SHADOW_S3_LIVE_\($0)"]?.isEmpty == false }
  }

  static func value(_ name: String) -> String? {
    values["SHADOW_S3_LIVE_\(name)"].flatMap { $0.isEmpty ? nil : $0 }
  }

  static func flag(_ name: String) -> Bool {
    ["1", "true", "yes"].contains(value(name)?.lowercased() ?? "")
  }
}

@Suite("S3StorageProvider live", TestTimeLimit.standard, .enabled(if: LiveEnvironment.isConfigured, "Set the SHADOW_S3_LIVE_* variables to run against a real bucket"))
struct S3LiveTests {
  @Test("should probe conditional writes and satisfy the conformance suite against a real bucket")
  func shouldConformLive() async throws {
    let base = try S3Configuration(
      endpoint: #require(LiveEnvironment.value("ENDPOINT").flatMap(URL.init(string:))),
      region: #require(LiveEnvironment.value("REGION")),
      bucket: #require(LiveEnvironment.value("BUCKET")),
      keyPrefix: "shadow-live-tests/\(UUID().uuidString.lowercased())",
      addressingStyle: LiveEnvironment.flag("PATH_STYLE") ? .path : .virtualHosted,
      allowsInsecureLocalhost: LiveEnvironment.flag("ALLOW_INSECURE_LOCALHOST")
    )
    let credentials = try S3Credentials(
      accessKeyID: #require(LiveEnvironment.value("ACCESS_KEY_ID")),
      secretAccessKey: #require(LiveEnvironment.value("SECRET_ACCESS_KEY")),
      sessionToken: LiveEnvironment.value("SESSION_TOKEN")
    )
    let probe = S3StorageProvider(configuration: base, credentials: credentials)
    let supported = try await probe.probeConditionalWrites()
    let provider = S3StorageProvider(configuration: base.withConditionalWrites(supported), credentials: credentials)

    var verification: (any Error)?
    do {
      try await StorageProviderConformance.verify(consistency: .eventual) { provider }
    } catch {
      verification = error
    }
    try await provider.delete(provider.listAll(prefix: "").map(\.key))
    #expect(try await provider.listAll(prefix: "").isEmpty)
    if let verification { throw verification }
  }
}
