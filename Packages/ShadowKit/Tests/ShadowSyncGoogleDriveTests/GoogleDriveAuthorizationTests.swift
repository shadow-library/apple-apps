import Foundation
import ShadowSync
import Testing

@testable import ShadowSyncGoogleDrive

@Suite("GoogleDriveProvider authorization", TestTimeLimit.quick)
struct GoogleDriveAuthorizationTests {
  @Test("should refresh once after a 401 and retry the request with the new token")
  func shouldRefreshOnce() async throws {
    let fake = FakeGoogleDrive()
    let id = fake.insert(name: "a", vault: DriveFixture.vault, data: Data([1]))
    let provider = try DriveFixture.provider(fake)
    fake.revokeAccessTokens()

    #expect(try await provider.get(DriveFixture.key("a")) == Data([1]))
    #expect(fake.tokenRequests == 1)
    #expect(fake.requests(.startPageToken).map(\.authorization) == ["Bearer access-0", "Bearer access-1"])
    #expect(fake.requests(.download).map(\.authorization) == ["Bearer access-1"])
    #expect(fake.requests(.download).first?.url.lastPathComponent == id)
  }

  @Test("should give up as unauthenticated when the refreshed token is rejected too")
  func shouldFailAfterSecondRejection() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake)
    fake.revokeAccessTokens()
    fake.setIssuesValidTokens(false)

    #expect(await DriveFixture.error { _ = try await provider.list(prefix: "", after: nil) } == .unauthenticated)
    #expect(fake.tokenRequests == 1)
    #expect(fake.requests(.startPageToken).count == 2)
  }

  @Test("should report unauthenticated when Google refuses the refresh token")
  func shouldFailOnInvalidGrant() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake)
    fake.revokeAccessTokens()
    fake.setRefreshRejected(true)

    #expect(await DriveFixture.error { _ = try await provider.list(prefix: "", after: nil) } == .unauthenticated)
    #expect(fake.requests(.startPageToken).count == 1)
  }

  @Test("should never send the bearer to a host outside the Drive API")
  func shouldKeepBearerOnDriveHost() async throws {
    let fake = FakeGoogleDrive()
    let id = fake.insert(name: "a", vault: DriveFixture.vault, data: Data([4]))
    fake.setRedirectsMedia(true)
    let provider = try DriveFixture.provider(fake)
    let key = try DriveFixture.key("a")

    #expect(try await provider.get(key) == Data([4]))
    let foreign = try #require(fake.requests(.foreignDownload).first)
    #expect(foreign.authorization == nil)
    #expect(foreign.url.host() == FakeGoogleDrive.foreignHost)
    #expect(fake.requests.filter { $0.url.host() != FakeGoogleDrive.foreignHost && $0.route != .token }.allSatisfy { $0.authorization == "Bearer access-0" })

    fake.setRedirectsMedia(false)
    fake.inject(.status(307, headers: ["Location": "https://www.googleapis.com/drive/v3/files/\(id)?alt=media&hop=1"]), on: .download)
    #expect(try await provider.get(key) == Data([4]))
    #expect(fake.requests(.download).suffix(2).map(\.authorization) == ["Bearer access-0", "Bearer access-0"])

    let before = fake.requests.count
    fake.inject(.status(302, headers: ["Location": "http://\(FakeGoogleDrive.foreignHost)/download/\(id)"]), on: .download)
    #expect(await DriveFixture.error { _ = try await provider.get(key) } == .unavailable("Google Drive redirected a download to an unusable address."))
    #expect(fake.requests.count == before + 1)

    fake.inject(.status(302, headers: ["Location": "https://www.googleapis.com/drive/v3/files/\(id)?alt=media"]), on: .download, times: 4)
    #expect(await DriveFixture.error { _ = try await provider.get(key) } == .unavailable("Google Drive redirected a download too many times."))
  }

  @Test("should keep tokens out of every error description")
  func shouldRedactErrors() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake)
    fake.inject(.transport(.timedOut), on: .startPageToken)
    let error = try #require(await DriveFixture.error { _ = try await provider.list(prefix: "", after: nil) })
    #expect(error == .unavailable("Google Drive could not be reached (URL error \(URLError.Code.timedOut.rawValue))."))
    #expect(!String(describing: error).contains("access-"))
    #expect(!String(describing: error).contains("googleapis"))
  }
}
