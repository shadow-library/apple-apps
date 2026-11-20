import Foundation
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncGoogleDrive

@Suite("GoogleDriveProvider conformance", TestTimeLimit.standard)
struct GoogleDriveConformanceTests {
  @Test("should satisfy the conformance suite against a consistent Drive")
  func shouldConform() async throws {
    let fake = FakeGoogleDrive()
    try await StorageProviderConformance.verify { try DriveFixture.provider(fake) }
    #expect(fake.requests(.multipart).isEmpty == false)
    #expect(fake.requests(.chunk).isEmpty)
  }

  @Test("should satisfy the conformance suite with resumable uploads, small pages and a finite object limit")
  func shouldConformWithSmallLimits() async throws {
    let fake = FakeGoogleDrive()
    var tuning = GoogleDriveTuning()
    tuning.maxObjectBytes = 3 * 1024 * 1024
    tuning.multipartLimit = 64 * 1024
    tuning.chunkBytes = 256 * 1024
    tuning.drivePageSize = 7
    tuning.listPageSize = 9
    try await StorageProviderConformance.verify { try DriveFixture.provider(fake, tuning: tuning) }
    #expect(fake.requests(.chunk).count >= 12)
    #expect(fake.openSessions == 0)
  }

  @Test("should satisfy the eventual conformance suite with a lagging feed and redirected downloads")
  func shouldConformEventually() async throws {
    let fake = FakeGoogleDrive()
    fake.setFeedLag(3)
    fake.setRedirectsMedia(true)
    var tuning = GoogleDriveTuning()
    tuning.drivePageSize = 5
    try await StorageProviderConformance.verify(consistency: .eventual) { try DriveFixture.provider(fake, tuning: tuning) }
    #expect(fake.requests(.foreignDownload).allSatisfy { $0.authorization == nil })
    #expect(fake.requests(.foreignDownload).isEmpty == false)
  }

  @Test("should report its capabilities")
  func shouldReportCapabilities() throws {
    let capabilities = try DriveFixture.provider(FakeGoogleDrive()).capabilities
    #expect(capabilities.pushesChangeNotices == false)
    #expect(capabilities.hasChangeFeed)
    #expect(capabilities.supportsPutIfAbsent == false)
    #expect(capabilities.reportsServerTime)
    #expect(capabilities.maxObjectBytes == GoogleDriveTuning.standardMaxObjectBytes)
    #expect(capabilities.classPolicy == .unrestricted)
  }
}
