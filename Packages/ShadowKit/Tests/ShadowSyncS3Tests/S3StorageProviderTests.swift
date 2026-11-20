import Foundation
import ShadowSync
import ShadowSyncS3
import ShadowTestSupport
import Testing

@Suite("S3StorageProvider conformance", TestTimeLimit.standard)
struct S3StorageProviderConformanceTests {
  @Test("should satisfy the conformance suite with conditional writes")
  func shouldConformWithConditionalWrites() async throws {
    let fake = FakeS3Service()
    try await StorageProviderConformance.verify { try S3Fixture.provider(fake) }

    #expect(fake.violations.isEmpty, "\(fake.violations)")
    #expect(fake.exchanges.contains { $0.headers["if-none-match"] == "*" })
    #expect(!fake.exchanges.contains { $0.operation == .head })
  }

  @Test("should satisfy the conformance suite with best-effort put-if-absent when the service ignores the condition")
  func shouldConformWithoutConditionalWrites() async throws {
    var options = FakeS3Service.Options()
    options.honorsConditionalWrites = false
    let fake = FakeS3Service(options)
    try await StorageProviderConformance.verify { try S3Fixture.provider(fake) }

    #expect(fake.violations.isEmpty, "\(fake.violations)")
    #expect(!fake.exchanges.contains { $0.headers["if-none-match"] != nil })
    #expect(fake.exchanges.contains { $0.operation == .head })
  }

  @Test("should satisfy the conformance suite under a key prefix beside foreign objects")
  func shouldConformUnderKeyPrefix() async throws {
    let fake = FakeS3Service()
    for name in [
      "users/ada/vaultz/conformance/roundtrip/empty", "users/ada/vault", "other/conformance/x", "users/ada/vault/conformance/page/bad name", "users/ada/vault/conformance/a+b",
    ] {
      fake.seed(name)
    }
    try await StorageProviderConformance.verify { try S3Fixture.provider(fake, keyPrefix: "users/ada/vault") }

    #expect(fake.violations.isEmpty, "\(fake.violations)")
    #expect(fake.objectNames.filter { !$0.hasPrefix("users/ada/vault/") }.count == 3)
  }

  @Test("should satisfy the conformance suite with path-style addressing, a port and a session token")
  func shouldConformPathStyle() async throws {
    var options = FakeS3Service.Options()
    options.style = .path
    options.endpointHost = "localhost:9000"
    options.bucket = "vaults.2026"
    options.sessionToken = "FwoGZXIvYXdzEBYaDEXAMPLE+/="
    let fake = FakeS3Service(options)
    try await StorageProviderConformance.verify { try S3Fixture.provider(fake, insecureLocalhost: true) }

    #expect(fake.violations.isEmpty, "\(fake.violations)")
  }
}

@Suite("S3StorageProvider", TestTimeLimit.quick)
struct S3StorageProviderTests {
  @Test("should report its capabilities from the configuration")
  func reportsCapabilities() throws {
    let on = try S3Fixture.provider(FakeS3Service(), conditionalWrites: true).capabilities
    let off = try S3Fixture.provider(FakeS3Service(), conditionalWrites: false).capabilities

    #expect(on.supportsPutIfAbsent && !off.supportsPutIfAbsent)
    #expect(on.reportsServerTime && !on.pushesChangeNotices && !on.hasChangeFeed)
    #expect(on.maxObjectBytes == S3StorageProvider.maxObjectBytes)
    guard case .unrestricted = on.classPolicy else {
      Issue.record("Expected an unrestricted class policy")
      return
    }
  }

  @Test("should list across pages in key order, strip the prefix and skip foreign and invalid names")
  func listsAcrossPages() async throws {
    var options = FakeS3Service.Options()
    options.pageSize = 3
    let fake = FakeS3Service(options)
    let names = ["vault/a", "vault/b/c", "vault/b/d", "vault/B", "vault/bad name", "vault/x+y", "vault/ctl\u{01}x", "vault/ü", "vault/dir/", "vault//z", "vaulty/a", "vault"]
    for name in names { fake.seed(name, Data(repeating: 7, count: name.utf8.count)) }
    let provider = try S3Fixture.provider(fake, keyPrefix: "vault")

    var pages = 0
    var cursor: ListCursor?
    var listed: [StorageObject] = []
    repeat {
      let page = try await provider.list(prefix: "", after: cursor)
      listed += page.objects
      cursor = page.next
      pages += 1
    } while cursor != nil && pages < 20

    #expect(listed.map(\.key.rawValue) == ["B", "a", "b/c", "b/d"])
    #expect(listed.map(\.size) == [7, 7, 9, 9])
    #expect(pages >= 4)
    #expect(fake.exchanges.allSatisfy { $0.query["encoding-type"] == "url" && $0.query["prefix"] == "vault/" })
    #expect(try await provider.listAll(prefix: "b/").map(\.key.rawValue) == ["b/c", "b/d"])
    #expect(fake.violations.isEmpty, "\(fake.violations)")
  }

  @Test("should not decode names when the service ignores the requested URL encoding")
  func keepsRawNamesWithoutEncoding() async throws {
    var options = FakeS3Service.Options()
    options.honorsEncodingType = false
    let fake = FakeS3Service(options)
    fake.seed("a%2Fb")
    fake.seed("a/b")

    #expect(try await S3Fixture.provider(fake).listAll(prefix: "").map(\.key.rawValue) == ["a/b"])
  }

  @Test("should continue after the last name when a truncated page has no continuation token")
  func continuesWithoutToken() async throws {
    var options = FakeS3Service.Options()
    options.pageSize = 2
    options.truncatesWithoutToken = true
    let fake = FakeS3Service(options)
    for name in ["a", "b", "c", "d", "e"] { fake.seed(name) }

    #expect(try await S3Fixture.provider(fake).listAll(prefix: "").map(\.key.rawValue) == ["a", "b", "c", "d", "e"])
    #expect(fake.exchanges.contains { $0.query["start-after"] == "b" })
  }

  @Test("should refuse a listing that is not in key order")
  func refusesUnorderedListing() async throws {
    var options = FakeS3Service.Options()
    options.listsInReverse = true
    let fake = FakeS3Service(options)
    for name in ["a", "b"] { fake.seed(name) }
    let failure = await S3Fixture.failure { try await S3Fixture.provider(fake).list(prefix: "", after: nil) }

    guard case .underlying = failure else {
      Issue.record("Expected an out-of-order listing to fail, got \(String(describing: failure))")
      return
    }
  }

  @Test("should refuse a cursor it did not make")
  func refusesForeignCursor() async throws {
    let failure = await S3Fixture.failure { try await S3Fixture.provider(FakeS3Service()).list(prefix: "", after: ListCursor(token: "zzz")) }

    guard case .underlying = failure else {
      Issue.record("Expected a foreign cursor to be refused, got \(String(describing: failure))")
      return
    }
  }

  @Test("should report the server's Date header as the put's server time")
  func reportsServerTime() async throws {
    let fake = FakeS3Service()
    let receipt = try await S3Fixture.provider(fake).put(S3Fixture.key("a"), data: Data([1]), condition: .overwrite)

    #expect(receipt.serverTime == fake.options.serverDate)
    #expect(fake.exchanges.last?.headers["content-type"] == "application/octet-stream")
    #expect(fake.exchanges.last?.headers["content-length"] == "1")
  }

  @Test("should refuse data over the object limit before sending anything")
  func refusesOversizedData() async throws {
    let fake = FakeS3Service()
    let key = try S3Fixture.key("big")
    let failure = await S3Fixture.failure { try await S3Fixture.provider(fake).put(key, data: Data(count: S3StorageProvider.maxObjectBytes + 1), condition: .overwrite) }

    #expect(failure == .tooLarge(key, limit: S3StorageProvider.maxObjectBytes))
    #expect(fake.exchanges.isEmpty)
  }

  @Test("should check with HEAD before a best-effort put-if-absent and refuse an existing key without writing")
  func checksBeforeBestEffortPut() async throws {
    let fake = FakeS3Service()
    fake.seed("taken", Data("first".utf8))
    let provider = try S3Fixture.provider(fake, conditionalWrites: false)
    let key = try S3Fixture.key("taken")

    #expect(await S3Fixture.failure { try await provider.put(key, data: Data("second".utf8), condition: .ifAbsent) } == .alreadyExists(key))
    #expect(fake.exchanges.map(\.operation) == [.head])
    #expect(fake.object("taken") == Data("first".utf8))
  }

  @Test("should map a refused condition to alreadyExists and a conditional conflict to a retryable failure")
  func mapsConditionalFailures() async throws {
    let fake = FakeS3Service()
    let provider = try S3Fixture.provider(fake)
    let key = try S3Fixture.key("k")
    fake.inject(.init(operation: .put, status: 412, code: "PreconditionFailed"))
    fake.inject(.init(operation: .put, status: 409, code: "ConditionalRequestConflict", message: "A conflicting operation occurred."))

    #expect(await S3Fixture.failure { try await provider.put(key, data: Data(), condition: .ifAbsent) } == .alreadyExists(key))
    guard case .unavailable = await S3Fixture.failure({ try await provider.put(key, data: Data(), condition: .ifAbsent) }) else {
      Issue.record("Expected a conditional conflict to be retryable")
      return
    }
  }

  @Test("should delete in batches of at most 1000 unique keys with Content-MD5, and send nothing for no keys")
  func deletesInBatches() async throws {
    let fake = FakeS3Service()
    let keys = try (0..<2500).map { try S3Fixture.key("d/\($0)") }
    for key in keys { fake.seed("pre/\(key.rawValue)") }
    let provider = try S3Fixture.provider(fake, keyPrefix: "pre")

    try await provider.delete([])
    #expect(fake.exchanges.isEmpty)
    try await provider.delete(keys + keys.prefix(10))

    #expect(fake.exchanges.map(\.operation) == [.delete, .delete, .delete])
    #expect(fake.objectNames.isEmpty)
    #expect(fake.violations.isEmpty, "\(fake.violations)")
  }

  @Test("should ignore NoSuchKey in a delete result and fail on other per-key errors")
  func mapsPerKeyDeleteErrors() async throws {
    let fake = FakeS3Service()
    let provider = try S3Fixture.provider(fake)
    fake.failDelete(of: "gone", code: "NoSuchKey")
    try await provider.delete([S3Fixture.key("gone")])

    fake.failDelete(of: "locked", code: "AccessDenied")
    #expect(await S3Fixture.failure { try await provider.delete([S3Fixture.key("locked")]) } == .unauthenticated)
    fake.failDelete(of: "busy", code: "InternalError")
    guard case .unavailable = await S3Fixture.failure({ try await provider.delete([S3Fixture.key("busy")]) }) else {
      Issue.record("Expected a per-key internal error to be retryable")
      return
    }
  }

  @Test("should sign the lowercased host of a mixed-case endpoint, as the Host header is sent")
  func signsLowercasedHost() async throws {
    let fake = FakeS3Service()
    let provider = try S3Fixture.provider(fake, endpoint: "https://S3.Test.Example")
    let key = try S3Fixture.key("a")
    _ = try await provider.put(key, data: Data([1]), condition: .overwrite)

    #expect(try await provider.get(key) == Data([1]))
    #expect(fake.violations.isEmpty, "\(fake.violations)")
  }

  @Test("should sign the punycode host of an internationalized endpoint, as it goes on the wire")
  func signsEncodedHost() async throws {
    var options = FakeS3Service.Options()
    options.endpointHost = "xn--bcher-kva.example"
    let fake = FakeS3Service(options)
    let provider = try S3Fixture.provider(fake, endpoint: "https://bücher.example")
    let key = try S3Fixture.key("a")
    _ = try await provider.put(key, data: Data([1]), condition: .overwrite)

    #expect(try await provider.get(key) == Data([1]))
    #expect(fake.violations.isEmpty, "\(fake.violations)")
  }

  @Test("should refuse to return an object whose declared length is over the limit")
  func refusesOversizedObject() async throws {
    let fake = FakeS3Service()
    fake.seed("planted")
    fake.inject(.init(operation: .get, status: 200, headers: ["Content-Length": String(S3StorageProvider.maxObjectBytes + 1)]))
    let key = try S3Fixture.key("planted")

    #expect(await S3Fixture.failure { try await S3Fixture.provider(fake).get(key) } == .tooLarge(key, limit: S3StorageProvider.maxObjectBytes))
  }

  @Test("should return notFound for a missing key")
  func returnsNotFound() async throws {
    let key = try S3Fixture.key("missing")

    #expect(await S3Fixture.failure { try await S3Fixture.provider(FakeS3Service()).get(key) } == .notFound(key))
  }

  @Test("should never yield change notices")
  func neverYieldsChangeNotices() async throws {
    let provider = try S3Fixture.provider(FakeS3Service())
    let first = Task { await provider.changeNotices().first { _ in true } }
    try await Task.sleep(for: .milliseconds(50))
    first.cancel()

    #expect(await first.value == nil)
  }
}
