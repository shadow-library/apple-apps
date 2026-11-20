import Foundation
import ShadowSync
import ShadowSyncOneDrive
import ShadowTestSupport
import Testing

@Suite("OneDriveStorageProvider conformance", TestTimeLimit.standard)
struct OneDriveConformanceTests {
  @Test("should satisfy the conformance suite against a consistent Graph")
  func conforms() async throws {
    let harness = try OneDriveHarness()
    try await StorageProviderConformance.verify { try harness.provider() }
    #expect(harness.graph.openSessions == 0)
  }

  @Test("should satisfy the conformance suite when every upload goes through an upload session in 320 KiB fragments")
  func conformsThroughUploadSessions() async throws {
    let harness = try OneDriveHarness()
    try await StorageProviderConformance.verify {
      try harness.provider(OneDriveProviderOptions(pageSize: 7, simpleUploadLimit: 0, uploadFragmentBytes: OneDriveProviderOptions.fragmentUnit))
    }
    #expect(harness.graph.requests.contains { $0.url.host() == FakeGraph.uploadHost && $0.method == "PUT" })
    #expect(harness.graph.openSessions == 0)
  }

  @Test("should satisfy the conformance suite with short delta pages, short listing pages and a small object limit")
  func conformsWithSmallLimits() async throws {
    let graph = FakeGraph()
    graph.configure { $0.deltaPageSize = 3 }
    let harness = try OneDriveHarness(graph: graph)
    try await StorageProviderConformance.verify { try harness.provider(OneDriveProviderOptions(pageSize: 5, maxObjectBytes: 1024)) }
  }

  @Test("should satisfy the eventual conformance suite when the delta feed lags behind writes")
  func conformsEventuallyWithLaggingDelta() async throws {
    let graph = FakeGraph()
    graph.configure { $0.lagStep = 2 }
    let harness = try OneDriveHarness(graph: graph)
    try await StorageProviderConformance.verify(consistency: .eventual) { try harness.provider(OneDriveProviderOptions(pageSize: 11)) }
  }

  @Test("should satisfy the conformance suite with a Graph that creates missing parents and a file-backed index")
  func conformsWithFileState() async throws {
    let graph = FakeGraph()
    graph.configure { $0.createsParentsOnUpload = true }
    let directory = FileManager.default.temporaryDirectory.appending(path: "onedrive-state-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try OneDriveHarness(graph: graph, state: FileOneDriveStateStore(url: directory.appending(path: "index.json")))
    try await StorageProviderConformance.verify { try harness.provider() }
  }
}
