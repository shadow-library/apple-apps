import Foundation
import ShadowNetworking
import ShadowSync
import Testing

@testable import ShadowSyncGoogleDrive

@Suite("GoogleDriveProvider errors", TestTimeLimit.quick)
struct GoogleDriveErrorTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let fault: FakeGoogleDrive.Fault
    let route: FakeGoogleDrive.Route
    let expected: StorageError

    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(name: "403 rateLimitExceeded", fault: .status(403, reason: "rateLimitExceeded"), route: .changes, expected: .rateLimited(retryAfter: nil)),
    Case(
      name: "403 userRateLimitExceeded", fault: .status(403, reason: "userRateLimitExceeded", headers: ["Retry-After": "7"]), route: .download,
      expected: .rateLimited(retryAfter: .seconds(7))),
    Case(name: "429", fault: .status(429, headers: ["Retry-After": "3"]), route: .multipart, expected: .rateLimited(retryAfter: .seconds(3))),
    Case(name: "403 storageQuotaExceeded", fault: .status(403, reason: "storageQuotaExceeded"), route: .multipart, expected: .quotaExceeded),
    Case(name: "403 insufficientPermissions", fault: .status(403, reason: "insufficientPermissions"), route: .changes, expected: .unauthenticated),
    Case(name: "503", fault: .status(503), route: .download, expected: .unavailable("Google Drive responded with status 503.")),
    Case(name: "500 on delete", fault: .status(500), route: .delete, expected: .unavailable("Google Drive responded with status 500.")),
    Case(name: "400", fault: .status(400, reason: "badRequest"), route: .multipart, expected: .underlying("Google Drive responded with status 400 (badRequest).")),
    Case(
      name: "connection lost", fault: .transport(.networkConnectionLost), route: .download,
      expected: .unavailable("Google Drive could not be reached (URL error \(URLError.Code.networkConnectionLost.rawValue)).")),
  ]

  @Test("should map Drive failures to storage errors", arguments: cases)
  func shouldMapFailures(_ testCase: Case) async throws {
    let fake = FakeGoogleDrive()
    fake.insert(name: "existing", vault: DriveFixture.vault, data: Data([1]))
    let provider = try DriveFixture.provider(fake)
    _ = try await provider.list(prefix: "", after: nil)
    fake.insert(name: "later", vault: DriveFixture.vault, data: Data([2]))
    fake.inject(testCase.fault, on: testCase.route)
    let existing = try DriveFixture.key("existing")
    let fresh = try DriveFixture.key("fresh")

    let error: StorageError?
    switch testCase.route {
    case .changes: error = await DriveFixture.error { _ = try await provider.list(prefix: "", after: nil) }
    case .download: error = await DriveFixture.error { _ = try await provider.get(existing) }
    case .delete: error = await DriveFixture.error { try await provider.delete([existing]) }
    default: error = await DriveFixture.error { _ = try await provider.put(fresh, data: Data([3]), condition: .overwrite) }
    }
    #expect(error == testCase.expected)
    #expect(fake.requests(testCase.route).count == 1)
  }

  static let signInCases: [(OAuthError, StorageError)] = [
    (.reauthorizationRequired, .unauthenticated),
    (.notSignedIn, .unauthenticated),
    (.accessDenied(description: nil), .unauthenticated),
    (.authorizationFailed(error: "server_error", description: nil), .unauthenticated),
    (.stateMismatch, .unauthenticated),
    (.tokenRequestRejected(status: 401, error: "invalid_client", description: nil), .unauthenticated),
    (.tokenRequestRejected(status: 403, error: nil, description: nil), .unavailable("Google sign-in returned an unexpected response.")),
    (.malformedTokenResponse("The body is not a JSON token response."), .unavailable("Google sign-in returned an unexpected response.")),
    (.underlying("captive portal"), .unavailable("Google sign-in returned an unexpected response.")),
    (.unsupportedTokenType("mac"), .unavailable("Google sign-in returned an unexpected response.")),
    (.rateLimited(retryAfter: .seconds(2)), .rateLimited(retryAfter: .seconds(2))),
    (.serviceUnavailable(status: 503, retryAfter: nil), .unavailable("Google sign-in is unavailable.")),
    (.transport(URLError(.notConnectedToInternet)), .unavailable("Google sign-in is unavailable.")),
    (.cancelled, .unavailable("The Google Drive request was cancelled.")),
    (.tokenStorage("keychain item refresh-secret"), .underlying("The Google sign-in tokens could not be loaded or saved.")),
    (.invalidConfiguration("bad"), .underlying("The Google sign-in configuration is invalid.")),
  ]

  @Test("should map sign-in failures, keeping unauthenticated for those a new sign-in fixes")
  func shouldMapSignInFailures() {
    for (failure, expected) in Self.signInCases {
      #expect(GoogleDriveFailure.oauth(failure) == expected, "\(failure.code)")
    }
  }

  @Test("should report a captive portal answering the token request as unavailable, not signed out")
  func shouldTreatCaptivePortalAsUnavailable() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake)
    fake.revokeAccessTokens()
    fake.inject(.status(200, headers: ["Content-Type": "text/html"]), on: .token)
    let error = await DriveFixture.error { _ = try await provider.list(prefix: "", after: nil) }
    #expect(error == .unavailable("Google sign-in returned an unexpected response."))
  }

  @Test("should cap objects above the largest file the vault codecs can seal")
  func shouldFitLargestSealedObject() throws {
    let vault = try #require(VaultID(String(repeating: "v", count: VaultID.maximumLength)))
    let keyID = try #require(KeyID("01936f3e-0000-7000-8000-000000000001"))
    let key = try #require(VaultKey(id: keyID, rawBytes: Data(repeating: 0x42, count: 32)))
    let largest = max(SegmentCodec.maximumPayloadBytes, BaseCodec.maximumPartPayloadBytes) + 1
    let sealed = try VaultFile.seal(Data(count: largest), path: String(repeating: "k", count: ObjectKey.maxUTF8Length), vault: vault, key: key)
    #expect(sealed.count <= GoogleDriveTuning.standardMaxObjectBytes)
    #expect(GoogleDriveTuning.standardMaxObjectBytes == 72 * 1024 * 1024)
  }
}
