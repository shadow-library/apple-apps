import Foundation
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncCloudKit

@Suite("CloudKitStorageProvider conformance", TestTimeLimit.standard)
struct CloudKitConformanceTests {
  @Test("should satisfy the strong conformance suite against the fake zone")
  func shouldConform() async throws {
    let fake = FakeCloudKitZone()
    fake.configureLimits {
      $0.maxInlineBytes = CloudKitRecordLayout.inlineLimit
      $0.maxAssetBytes = CloudKitRecordLayout.partBytes
    }
    try await StorageProviderConformance.verify(consistency: .strong) { CloudKitFixture.provider(fake) }
    #expect(fake.zoneExists)
  }

  @Test("should satisfy the strong conformance suite with small parts, pages, batches and feed pages and a finite object limit")
  func shouldConformWithSmallLimits() async throws {
    let fake = FakeCloudKitZone()
    fake.configureLimits {
      $0.maxInlineBytes = 64
      $0.maxAssetBytes = 100
      $0.maxRecordsPerRequest = 2
      $0.feedPageSize = 3
    }
    var tuning = CloudKitTuning()
    tuning.inlineLimit = 64
    tuning.partBytes = 100
    tuning.maxObjectBytes = 1000
    tuning.listPageSize = 7
    tuning.batchSize = 3
    try await StorageProviderConformance.verify(consistency: .strong) { CloudKitFixture.provider(fake, tuning: tuning) }
    #expect(fake.batchSizes(.delete).contains(3))
    #expect(fake.batchSizes(.delete).contains { $0 > 2 })
  }

  @Test("should report its capabilities")
  func shouldReportCapabilities() {
    let capabilities = CloudKitFixture.provider(FakeCloudKitZone()).capabilities
    #expect(capabilities.pushesChangeNotices)
    #expect(capabilities.supportsPutIfAbsent)
    #expect(capabilities.hasChangeFeed)
    #expect(capabilities.reportsServerTime)
    #expect(capabilities.maxObjectBytes == 72 * 1024 * 1024)
    #expect(capabilities.classPolicy == .iCloud)
  }
}
