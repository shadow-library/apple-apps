import Foundation
import ShadowNetworking
import ShadowSync
import ShadowSyncOneDrive
import ShadowTestSupport
import Testing

@Suite("OneDriveStorageProvider transfers", TestTimeLimit.quick)
struct OneDriveTransferTests {
  private static func onGraph(_ method: String, pathContaining fragment: String) -> @Sendable (FakeGraph.Recorded) -> Bool {
    { $0.url.host() == FakeGraph.graphHost && $0.method == method && $0.url.absoluteString.contains(fragment) }
  }

  private static func payload(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
  }

  @Test("should send the bearer token to Graph only and never to the download host")
  func keepsTokenOffDownloadHost() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("doc"), data: Data([4, 2]), condition: .overwrite)
    #expect(try await provider.get(try key("doc")) == Data([4, 2]))
    let downloads = harness.graph.requests.filter { $0.url.host() == FakeGraph.downloadHost }
    #expect(downloads.count == 1)
    #expect(downloads.allSatisfy { $0.authorization == nil })
    #expect(harness.graph.requests.filter { $0.url.host() == FakeGraph.graphHost }.allSatisfy { $0.authorization == "Bearer access-0" })
  }

  @Test("should refuse to follow a delta link off Microsoft Graph")
  func refusesForeignDeltaLink() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("doc"), data: Data([1]), condition: .overwrite)
    harness.graph.inject(status: 200, body: #"{"value":[],"@odata.nextLink":"https://evil.example/steal"}"#, when: Self.onGraph("GET", pathContaining: "/delta"))
    let error = await storageError { _ = try await provider.list(prefix: "", after: nil) }
    #expect(error == .underlying("refusing to send the Microsoft token outside Microsoft Graph"))
    #expect(!harness.graph.requests.contains { $0.url.host() == "evil.example" })
  }

  @Test("should refresh once after a 401 and retry the request with the new token")
  func refreshesOnceAfterRejection() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("doc"), data: Data([1]), condition: .overwrite)
    harness.graph.revokeAccessTokens()
    #expect(try await provider.get(try key("doc")) == Data([1]))
    let tokenRequests = harness.graph.requests.filter { $0.url.host() == FakeGraph.tokenHost }
    #expect(tokenRequests.count == 1)
    let contentRequests = harness.graph.requests.filter { $0.url.absoluteString.hasSuffix(":/content") && $0.method == "GET" }
    #expect(contentRequests.map(\.authorization) == ["Bearer access-0", "Bearer access-1"])
    #expect(await harness.tokens.tokens?.refreshToken == "refresh-1")
  }

  @Test("should report unauthenticated when the retried request is rejected again or the refresh is refused")
  func reportsUnauthenticated() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    let doc = try key("doc")
    for _ in 0..<2 { harness.graph.inject(status: 401, when: Self.onGraph("GET", pathContaining: ":/content")) }
    #expect(await storageError { _ = try await provider.get(doc) } == .unauthenticated)
    #expect(harness.graph.requests.filter { $0.url.host() == FakeGraph.tokenHost }.count == 1)
    harness.graph.revokeAccessTokens()
    harness.graph.configure { $0.refreshFails = true }
    #expect(await storageError { _ = try await provider.get(doc) } == .unauthenticated)
  }

  @Test(
    "should map Graph failures to storage errors without leaking tokens",
    arguments: [
      (429, ["Retry-After": "7"], "", StorageError.rateLimited(retryAfter: .seconds(7))),
      (503, ["Retry-After": "3"], "", StorageError.rateLimited(retryAfter: .seconds(3))),
      (503, [:], "", StorageError.unavailable("Microsoft Graph answered 503")),
      (500, [:], #"{"error":{"code":"generalException"}}"#, StorageError.unavailable("Microsoft Graph answered 500 (generalException)")),
      (507, [:], #"{"error":{"code":"insufficientStorage"}}"#, StorageError.quotaExceeded),
      (403, [:], #"{"error":{"code":"quotaLimitReached"}}"#, StorageError.quotaExceeded),
      (403, [:], #"{"error":{"code":"accessDenied"}}"#, StorageError.unauthenticated),
      (400, [:], #"{"error":{"code":"invalidRequest","innererror":{"code":"badArgument"}}}"#, StorageError.underlying("Microsoft Graph answered 400 (invalidRequest)")),
    ])
  func mapsFailures(status: Int, headers: [String: String], body: String, expected: StorageError) async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    harness.graph.inject(status: status, headers: headers, body: body, when: Self.onGraph("PUT", pathContaining: ":/content"))
    let error = await storageError { _ = try await provider.put(try key("doc"), data: Data([1]), condition: .overwrite) }
    #expect(error == expected)
    #expect(error.map { "\($0) \($0.errorDescription ?? "")" }?.contains("access-") == false)
  }

  @Test("should map a refusal during a delta catch-up and keep the index it had")
  func mapsCatchUpFailure() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("doc"), data: Data([1]), condition: .overwrite)
    #expect(try await provider.listAll(prefix: "").count == 1)
    harness.graph.inject(status: 429, headers: ["Retry-After": "Fri, 01 Jan 2100 00:00:00 GMT"], when: Self.onGraph("GET", pathContaining: "/delta"))
    let throttled = await storageError { _ = try await provider.list(prefix: "", after: nil) }
    guard case .rateLimited(let retryAfter?) = throttled else {
      Issue.record("expected rateLimited, got \(String(describing: throttled))")
      return
    }
    #expect(retryAfter > .zero)
    #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["doc"])
  }

  @Test("should stamp a put with the server's Date header")
  func reportsServerTime() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    #expect(provider.capabilities.reportsServerTime)
    let receipt = try await provider.put(try key("doc"), data: Data([1]), condition: .overwrite)
    #expect(receipt.serverTime == FakeGraph.serverDate)
  }

  @Test("should refuse an object over the limit before sending anything")
  func refusesTooLarge() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider(OneDriveProviderOptions(maxObjectBytes: 10))
    let doc = try key("doc")
    #expect(await storageError { _ = try await provider.put(doc, data: Self.payload(11), condition: .overwrite) } == .tooLarge(doc, limit: 10))
    #expect(harness.graph.requests.isEmpty)
  }

  @Test("should resume an upload session after a dropped fragment and a server error")
  func resumesUploadSession() async throws {
    let harness = try OneDriveHarness()
    let unit = OneDriveProviderOptions.fragmentUnit
    let provider = try harness.provider(OneDriveProviderOptions(simpleUploadLimit: 0, uploadFragmentBytes: unit))
    let data = Self.payload(unit * 3 + 17)
    harness.graph.inject(URLError(.networkConnectionLost)) { $0.url.host() == FakeGraph.uploadHost && $0.contentRange?.hasPrefix("bytes \(unit)-") == true }
    harness.graph.inject(status: 502) { $0.url.host() == FakeGraph.uploadHost && $0.contentRange?.hasPrefix("bytes \(unit * 2)-") == true }
    _ = try await provider.put(try key("big"), data: data, condition: .overwrite)
    #expect(try await provider.get(try key("big")) == data)
    let uploads = harness.graph.requests.filter { $0.url.host() == FakeGraph.uploadHost }
    #expect(uploads.filter { $0.method == "GET" }.count == 2)
    #expect(uploads.allSatisfy { $0.authorization == nil })
    #expect(harness.graph.openSessions == 0)
  }

  @Test("should give up after the allowed resumes and cancel the session, leaving no file")
  func cancelsAfterRepeatedFailures() async throws {
    let harness = try OneDriveHarness()
    let unit = OneDriveProviderOptions.fragmentUnit
    let provider = try harness.provider(OneDriveProviderOptions(simpleUploadLimit: 0, uploadFragmentBytes: unit, uploadResumes: 1))
    for _ in 0..<2 { harness.graph.inject(status: 500) { $0.url.host() == FakeGraph.uploadHost && $0.method == "PUT" } }
    let big = try key("big")
    #expect(await storageError { _ = try await provider.put(big, data: Self.payload(unit * 2), condition: .overwrite) } == .unavailable("Microsoft Graph answered 500"))
    #expect(harness.graph.openSessions == 0)
    #expect(harness.graph.requests.contains { $0.url.host() == FakeGraph.uploadHost && $0.method == "DELETE" })
    #expect(await storageError { _ = try await provider.get(big) } == .notFound(big))
  }

  @Test("should report alreadyExists when a name is taken during an upload session and cancel the session")
  func reportsConflictAtCompletion() async throws {
    let harness = try OneDriveHarness()
    let unit = OneDriveProviderOptions.fragmentUnit
    let provider = try harness.provider(OneDriveProviderOptions(simpleUploadLimit: 0, uploadFragmentBytes: unit))
    let data = Self.payload(unit + 5)
    harness.graph.inject(status: 409, body: #"{"error":{"code":"nameAlreadyExists"}}"#) {
      $0.url.host() == FakeGraph.uploadHost && $0.contentRange?.hasSuffix("/\(unit + 5)") == true && $0.contentRange?.hasPrefix("bytes \(unit)-") == true
    }
    let late = try key("late")
    #expect(await storageError { _ = try await provider.put(late, data: data, condition: .ifAbsent) } == .alreadyExists(late))
    #expect(harness.graph.openSessions == 0)
    #expect(harness.graph.fileNames.isEmpty)
  }

  @Test("should start the upload again when the session disappears")
  func restartsVanishedSession() async throws {
    let harness = try OneDriveHarness()
    let unit = OneDriveProviderOptions.fragmentUnit
    let provider = try harness.provider(OneDriveProviderOptions(simpleUploadLimit: 0, uploadFragmentBytes: unit))
    harness.graph.inject(status: 404, body: #"{"error":{"code":"itemNotFound"}}"#) { $0.url.host() == FakeGraph.uploadHost && $0.contentRange?.hasPrefix("bytes \(unit)-") == true }
    _ = try await provider.put(try key("empty"), data: Data(), condition: .ifAbsent)
    let data = Self.payload(unit * 2)
    _ = try await provider.put(try key("big"), data: data, condition: .ifAbsent)
    #expect(try await provider.get(try key("big")) == data)
    #expect(harness.graph.requests.filter { $0.url.absoluteString.hasSuffix(":/createUploadSession") }.count == 2)
  }

  @Test("should delete many keys in batches of twenty, ignoring missing ones")
  func deletesInBatches() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    let keys = try (0..<45).map { try key("d/\($0)") }
    for key in keys.prefix(30) { _ = try await provider.put(key, data: Data([1]), condition: .overwrite) }
    try await provider.delete(keys + keys.prefix(3))
    #expect(harness.graph.requests.filter { $0.url.path().hasSuffix("/$batch") }.count == 3)
    #expect(try await provider.listAll(prefix: "d/").isEmpty)
    #expect(harness.graph.fileNames.isEmpty)
  }

  @Test("should surface a throttled delete inside a batch")
  func surfacesThrottledBatchDelete() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    let keys = try (0..<3).map { try key("d/\($0)") }
    for key in keys { _ = try await provider.put(key, data: Data([1]), condition: .overwrite) }
    harness.graph.inject(
      status: 200, body: #"{"responses":[{"id":"0","status":204},{"id":"1","status":429,"headers":{"Retry-After":"9"}},{"id":"2","status":404}]}"#,
      when: Self.onGraph("POST", pathContaining: "/$batch"))
    #expect(await storageError { try await provider.delete(keys) } == .rateLimited(retryAfter: .seconds(9)))
  }

  @Test("should create the vault folder once when the first upload finds it missing")
  func createsVaultFolder() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    #expect(harness.vaultFolderID == nil)
    #expect(try await provider.listAll(prefix: "").isEmpty)
    _ = try await provider.put(try key("first"), data: Data([1]), condition: .ifAbsent)
    #expect(harness.vaultFolderID != nil)
    #expect(harness.graph.requests.filter { $0.url.path().hasSuffix("/approot/children") }.count == 1)
    #expect(harness.graph.fileNames == ["first"])
  }

  @Test("should keep keys that differ only by case apart on a case-insensitive drive")
  func keepsCaseVariantsApart() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    for raw in ["Doc", "doc", "DOC"] { _ = try await provider.put(try key(raw), data: Data(raw.utf8), condition: .ifAbsent) }
    for raw in ["Doc", "doc", "DOC"] { #expect(try await provider.get(try key(raw)) == Data(raw.utf8)) }
    #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["DOC", "Doc", "doc"])
  }

  @Test("should never yield change notices")
  func neverYieldsNotices() async throws {
    let provider = try OneDriveHarness().provider()
    #expect(!provider.capabilities.pushesChangeNotices)
    #expect(provider.capabilities.hasChangeFeed)
    #expect(provider.capabilities.supportsPutIfAbsent)
    let notices = provider.changeNotices()
    let yielded = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in notices { return true }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: .milliseconds(50))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    #expect(!yielded)
  }
}
