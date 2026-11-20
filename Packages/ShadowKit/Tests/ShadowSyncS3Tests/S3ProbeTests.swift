import Foundation
import ShadowSync
import ShadowSyncS3
import Testing

@Suite("S3StorageProvider conditional-write probe", TestTimeLimit.quick)
struct S3ProbeTests {
  private static let probeName = "vault/" + S3StorageProvider.conditionalWriteProbeKey.rawValue

  @Test("should find conditional writes supported and leave nothing behind")
  func findsSupport() async throws {
    let fake = FakeS3Service()
    let provider = try S3Fixture.provider(fake, keyPrefix: "vault", conditionalWrites: false)

    #expect(try await provider.probeConditionalWrites())
    #expect(fake.objectNames.isEmpty)
    #expect(fake.exchanges.filter { $0.operation == .put }.allSatisfy { $0.objectName == Self.probeName && $0.headers["if-none-match"] == "*" })
    #expect(fake.violations.isEmpty, "\(fake.violations)")
  }

  @Test("should find conditional writes unsupported when the service ignores the condition, and clean up")
  func findsIgnoredCondition() async throws {
    var options = FakeS3Service.Options()
    options.honorsConditionalWrites = false
    let fake = FakeS3Service(options)

    #expect(try await S3Fixture.provider(fake, keyPrefix: "vault").probeConditionalWrites() == false)
    #expect(fake.objectNames.isEmpty)
  }

  @Test("should find conditional writes unsupported when the service refuses the condition as not implemented")
  func findsUnimplementedCondition() async throws {
    var options = FakeS3Service.Options()
    options.refusesConditionalWritesAsUnimplemented = true
    let fake = FakeS3Service(options)

    #expect(try await S3Fixture.provider(fake).probeConditionalWrites() == false)
    #expect(fake.objectNames.isEmpty)
  }

  @Test("should remove a probe object a crashed run left long ago and probe again")
  func removesStaleLeftover() async throws {
    let fake = FakeS3Service()
    fake.seed(Self.probeName, Data("stale".utf8), lastModified: fake.options.serverDate.addingTimeInterval(-3_600))

    #expect(try await S3Fixture.provider(fake, keyPrefix: "vault").probeConditionalWrites())
    #expect(fake.objectNames.isEmpty)
  }

  @Test("should leave a recent probe object alone and throw, since another device may be probing")
  func leavesConcurrentProbeAlone() async throws {
    let fake = FakeS3Service()
    fake.seed(Self.probeName, Data("other device".utf8), lastModified: fake.options.serverDate.addingTimeInterval(-30))
    let failure = await S3Fixture.failure { try await S3Fixture.provider(fake, keyPrefix: "vault").probeConditionalWrites() }

    guard case .unavailable = failure else {
      Issue.record("Expected an inconclusive probe, got \(String(describing: failure))")
      return
    }
    #expect(fake.object(Self.probeName) == Data("other device".utf8))
    #expect(!fake.exchanges.contains { $0.operation == .delete })
  }

  @Test("should write again without deleting when the refusing object is gone by the time it is checked")
  func retriesWhenLeftoverIsGone() async throws {
    let fake = FakeS3Service()
    fake.inject(.init(operation: .put, status: 412, code: "PreconditionFailed"))

    #expect(try await S3Fixture.provider(fake, keyPrefix: "vault").probeConditionalWrites())
    #expect(Array(fake.exchanges.map(\.operation).prefix(3)) == [.put, .head, .put])
    #expect(fake.exchanges.filter { $0.operation == .delete }.count == 1)
    #expect(fake.objectNames.isEmpty)
  }

  @Test("should throw when a stale leftover is still refused after its removal, without a third write")
  func stopsAfterOneRetry() async throws {
    let fake = FakeS3Service()
    fake.seed(Self.probeName, Data("stale".utf8), lastModified: fake.options.serverDate.addingTimeInterval(-3_600))
    fake.inject(.init(operation: .put, status: 412, code: "PreconditionFailed", skip: 1))
    let failure = await S3Fixture.failure { try await S3Fixture.provider(fake, keyPrefix: "vault").probeConditionalWrites() }

    guard case .unavailable = failure else {
      Issue.record("Expected an inconclusive probe, got \(String(describing: failure))")
      return
    }
    #expect(fake.exchanges.map(\.operation) == [.put, .head, .delete, .put])
  }

  @Test("should throw an inconclusive probe without deleting anything it may not have written")
  func throwsWhenInterrupted() async throws {
    let fake = FakeS3Service()
    let provider = try S3Fixture.provider(fake, keyPrefix: "vault")
    fake.inject(.init(operation: .put, status: 0, transportError: URLError(.networkConnectionLost)))
    fake.inject(.init(operation: .put, status: 500, code: "InternalError", remaining: 2))

    for _ in 0..<3 {
      guard case .unavailable = await S3Fixture.failure({ try await provider.probeConditionalWrites() }) else {
        Issue.record("Expected an inconclusive probe to throw unavailable")
        return
      }
    }
    #expect(fake.exchanges.map(\.operation) == [.put, .put, .put])
  }

  @Test("should throw when the second write fails and still remove the first write's object")
  func throwsWhenSecondWriteFails() async throws {
    let fake = FakeS3Service()
    let provider = try S3Fixture.provider(fake, keyPrefix: "vault")
    fake.inject(.init(operation: .put, status: 503, code: "ServiceUnavailable", skip: 1))
    let failure = await S3Fixture.failure { try await provider.probeConditionalWrites() }

    guard case .unavailable = failure else {
      Issue.record("Expected the probe to fail, got \(String(describing: failure))")
      return
    }
    #expect(fake.exchanges.map(\.operation) == [.put, .put, .delete])
    #expect(fake.objectNames.isEmpty)
  }

  @Test("should record a probe's answer in a new configuration")
  func recordsAnswer() throws {
    let configuration = try S3Configuration(endpoint: #require(URL(string: "https://s3.example.com")), region: "auto", bucket: "shadow-vaults")
    let probed = configuration.withConditionalWrites(true)

    #expect(!configuration.supportsConditionalWrites)
    #expect(probed.supportsConditionalWrites)
    #expect(probed.withConditionalWrites(false) == configuration)
  }
}
