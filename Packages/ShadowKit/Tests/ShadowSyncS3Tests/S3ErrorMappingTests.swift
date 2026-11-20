import Foundation
import ShadowSync
import ShadowSyncS3
import Testing

@Suite("S3StorageProvider errors", TestTimeLimit.quick)
struct S3ErrorMappingTests {
  private static func getFailure(_ fake: FakeS3Service, secretAccessKey: String? = nil, clockOffset: TimeInterval = 0) async throws -> StorageError? {
    let provider = try S3Fixture.provider(fake, secretAccessKey: secretAccessKey, clockOffset: clockOffset)
    let key = try S3Fixture.key("k")
    return await S3Fixture.failure { try await provider.get(key) }
  }

  private static func injected(_ fault: FakeS3Service.Fault) -> FakeS3Service {
    let fake = FakeS3Service()
    fake.seed("k")
    fake.inject(fault)
    return fake
  }

  private static func message(_ error: StorageError?) -> String? {
    guard case .unavailable(let message) = error else { return nil }
    return message
  }

  @Test("should honour Retry-After in seconds or as an HTTP date when the service slows requests down")
  func mapsRateLimits() async throws {
    let date = FakeS3Service.httpDate(FakeS3Service.Options().serverDate.addingTimeInterval(42))

    #expect(
      try await Self.getFailure(Self.injected(.init(status: 503, code: "SlowDown", headers: ["Retry-After": "3"]))) == .rateLimited(retryAfter: .seconds(3)))
    #expect(try await Self.getFailure(Self.injected(.init(status: 429, code: nil, headers: ["Retry-After": date]))) == .rateLimited(retryAfter: .seconds(42)))
    #expect(try await Self.getFailure(Self.injected(.init(status: 503, code: "SlowDown"))) == .rateLimited(retryAfter: nil))
  }

  @Test("should treat server errors and transport failures as unavailable")
  func mapsServerErrors() async throws {
    #expect(Self.message(try await Self.getFailure(Self.injected(.init(status: 500, code: "InternalError", message: "We encountered an internal error.")))) != nil)
    #expect(Self.message(try await Self.getFailure(Self.injected(.init(status: 502, code: nil)))) != nil)
    #expect(Self.message(try await Self.getFailure(Self.injected(.init(status: 0, transportError: URLError(.notConnectedToInternet))))) != nil)
  }

  @Test("should treat refused credentials as unauthenticated", arguments: ["InvalidAccessKeyId", "SignatureDoesNotMatch", "AccessDenied", "ExpiredToken", "InvalidToken"])
  func mapsAuthenticationCodes(code: String) async throws {
    #expect(try await Self.getFailure(Self.injected(.init(status: code == "ExpiredToken" ? 400 : 403, code: code))) == .unauthenticated)
  }

  @Test("should report a wrong secret key as unauthenticated without revealing it")
  func mapsWrongSecret() async throws {
    let fake = FakeS3Service()
    fake.seed("k")
    let failure = try await Self.getFailure(fake, secretAccessKey: "wrong/secret")

    #expect(failure == .unauthenticated)
    #expect(fake.violations.isEmpty, "\(fake.violations)")
  }

  @Test("should explain a skewed device clock with its direction and size")
  func mapsClockSkew() async throws {
    let fake = FakeS3Service()
    fake.seed("k")
    let message = try #require(Self.message(try await Self.getFailure(fake, clockOffset: 20 * 60)))

    #expect(message.contains("about 20 minutes ahead of"))
    #expect(message.contains("date and time"))
  }

  @Test("should name a missing bucket")
  func mapsMissingBucket() async throws {
    var options = FakeS3Service.Options()
    options.bucketExists = false
    let message = try #require(Self.message(try await Self.getFailure(FakeS3Service(options))))

    #expect(message.contains("shadow-vaults") && message.contains("does not exist"))
  }

  @Test("should name the bucket's region when the endpoint redirects")
  func mapsRedirects() async throws {
    let fault = FakeS3Service.Fault(status: 301, code: "PermanentRedirect", message: "Use the specified endpoint.", headers: ["x-amz-bucket-region": "ap-south-1"])
    let message = try #require(Self.message(try await Self.getFailure(Self.injected(fault))))

    #expect(message.contains("ap-south-1"))
  }

  @Test("should recognise quota errors from S3-compatible services")
  func mapsQuotas() async throws {
    #expect(try await Self.getFailure(Self.injected(.init(status: 403, code: "QuotaExceeded"))) == .quotaExceeded)
    #expect(try await Self.getFailure(Self.injected(.init(status: 400, code: "XMinioAdminBucketQuotaExceeded"))) == .quotaExceeded)
    #expect(try await Self.getFailure(Self.injected(.init(status: 403, code: "AccessDenied", message: "Cannot upload files, storage cap exceeded."))) == .quotaExceeded)
  }

  @Test("should map an entity too large to tooLarge for the key")
  func mapsEntityTooLarge() async throws {
    let fake = Self.injected(.init(operation: .put, status: 400, code: "EntityTooLarge"))
    let key = try S3Fixture.key("k")
    let failure = await S3Fixture.failure { try await S3Fixture.provider(fake).put(key, data: Data([1]), condition: .overwrite) }

    #expect(failure == .tooLarge(key, limit: S3StorageProvider.maxObjectBytes))
  }

  @Test("should keep other client errors permanent")
  func mapsClientErrors() async throws {
    guard case .underlying(let message) = try await Self.getFailure(Self.injected(.init(status: 400, code: "InvalidArgument", message: "Bad\n\tinput "))) else {
      Issue.record("Expected a permanent failure")
      return
    }
    #expect(message == "HTTP 400 InvalidArgument: Bad input")
  }

  @Test("should never put credentials into error text")
  func redactsCredentials() async throws {
    let options = FakeS3Service.Options()
    let echoed = "key \(options.accessKeyID) secret \(options.secretAccessKey) rejected"
    let failure = try await Self.getFailure(Self.injected(.init(status: 400, code: "InvalidRequest", message: echoed)))
    let text = String(describing: try #require(failure))

    #expect(!text.contains(options.secretAccessKey))
    #expect(!text.contains(options.accessKeyID))
    #expect(text.contains("<redacted>"))
  }
}
