import Foundation
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncOneDrive

@Suite("OneDriveStorageProvider index", TestTimeLimit.quick)
struct OneDriveIndexTests {
  private static func keys(_ provider: OneDriveStorageProvider, prefix: String = "") async throws -> [String] {
    try await provider.listAll(prefix: prefix).map(\.key.rawValue)
  }

  private static func deltaRequests(_ graph: FakeGraph) -> [URL] {
    graph.requests.filter { $0.url.host() == FakeGraph.graphHost && $0.url.path().hasSuffix("/delta") }.map(\.url)
  }

  @Test("should list only files the delta feed reported, while reads find files the feed has not reached")
  func listsOnlyReportedFiles() async throws {
    let graph = FakeGraph()
    graph.configure { $0.lagStep = 0 }
    let harness = try OneDriveHarness(graph: graph)
    let provider = try harness.provider()
    _ = try await provider.put(try key("a"), data: Data([1]), condition: .overwrite)
    #expect(try await Self.keys(provider).isEmpty)
    #expect(try await provider.get(try key("a")) == Data([1]))
    graph.configure { $0.lagStep = nil }
    #expect(try await Self.keys(provider) == ["a"])
  }

  @Test("should ignore folders, nested files, foreign names and files outside the vault folder")
  func ignoresForeignItems() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("kept"), data: Data([1, 2]), condition: .overwrite)
    let folderID = try #require(harness.vaultFolderID)
    let nested = harness.graph.seedFolder(name: "sub", in: folderID)
    harness.graph.seedFile(name: "inner", data: Data([1]), in: nested)
    for name in ["Readme.txt", "a b", "x.", "~2plain", "a~0b"] { harness.graph.seedFile(name: name, data: Data([1]), in: folderID) }
    harness.graph.seedFile(name: "outside", data: Data([1]))
    _ = harness.graph.seedFolder(name: "folderkey", in: folderID)
    let listed = try await provider.listAll(prefix: "")
    #expect(listed == [StorageObject(key: try key("kept"), size: 2)])
  }

  @Test("should drop entries when the feed reports a deletion without a name or a rename to a foreign name")
  func dropsDeletedAndRenamedItems() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    for raw in ["a", "b", "c"] { _ = try await provider.put(try key(raw), data: Data([7]), condition: .overwrite) }
    #expect(try await Self.keys(provider) == ["a", "b", "c"])
    let folderID = try #require(harness.vaultFolderID)
    harness.graph.deleteItem(named: "a", in: folderID)
    harness.graph.renameItem(named: "b", in: folderID, to: "B b")
    harness.graph.renameItem(named: "c", in: folderID, to: "d")
    #expect(try await Self.keys(provider) == ["d"])
  }

  @Test("should replace the whole index from a fresh enumeration when the feed answers 410 Gone")
  func resyncReplacesIndex() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("real"), data: Data([1]), condition: .overwrite)
    #expect(try await Self.keys(provider) == ["real"])
    let stored = try #require(await (harness.state as? InMemoryOneDriveStateStore)?.state)
    var poisoned = stored
    poisoned.entries["ghost-id"] = OneDriveIndexEntry(itemID: "ghost-id", name: "ghost", key: try key("ghost"), size: 3, eTag: nil, cTag: nil)
    let reloaded = InMemoryOneDriveStateStore(state: poisoned)
    let second = try harness.provider(state: reloaded)
    #expect(try await Self.keys(second) == ["ghost", "real"])
    harness.graph.expireDeltaTokensOnce()
    #expect(try await Self.keys(second) == ["real"])
    let afterResync = Self.deltaRequests(harness.graph).last
    #expect(afterResync?.query() == nil)
    #expect(await reloaded.state?.entries.values.map(\.key.rawValue) == ["real"])
  }

  @Test("should resume the feed from a saved delta link instead of enumerating again")
  func resumesFromSavedState() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "onedrive-state-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileOneDriveStateStore(url: directory.appending(path: "nested/index.json"))
    let harness = try OneDriveHarness(state: store)
    let first = try harness.provider()
    for raw in ["x/1", "x/2"] { _ = try await first.put(try key(raw), data: Data([9, 9, 9]), condition: .overwrite) }
    #expect(try await Self.keys(first) == ["x/1", "x/2"])
    let saved = try #require(try await store.load())
    #expect(saved.entries.count == 2)
    #expect(saved.position.map { if case .caughtUp = $0 { true } else { false } } == true)
    let before = Self.deltaRequests(harness.graph).count
    let second = try harness.provider()
    #expect(try await second.listAll(prefix: "x/") == [StorageObject(key: try key("x/1"), size: 3), StorageObject(key: try key("x/2"), size: 3)])
    let resumed = Self.deltaRequests(harness.graph).dropFirst(before)
    #expect(resumed.count == 1)
    #expect(resumed.first?.query()?.contains("token=") == true)
  }

  @Test("should discard a saved index that belongs to another vault folder")
  func discardsForeignState() async throws {
    let other = try #require(VaultFolderName("Other Vault"))
    let ghost = OneDriveIndexEntry(itemID: "ghost-id", name: "ghost", key: try key("ghost"), size: 1, eTag: nil, cTag: nil)
    let store = InMemoryOneDriveStateStore(state: OneDriveIndexState(vaultFolder: other, folderID: "elsewhere", entries: ["ghost-id": ghost]))
    let harness = try OneDriveHarness(state: store)
    #expect(try await Self.keys(try harness.provider()).isEmpty)
  }

  @Test("should resume pages after the cursor's key while files appear before and after it")
  func cursorSurvivesConcurrentPuts() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider(OneDriveProviderOptions(pageSize: 2))
    for raw in ["a", "c", "e"] { _ = try await provider.put(try key(raw), data: Data([1]), condition: .overwrite) }
    let first = try await provider.list(prefix: "", after: nil)
    #expect(first.objects.map(\.key.rawValue) == ["a", "c"])
    for raw in ["b", "d", "f"] { _ = try await provider.put(try key(raw), data: Data([1]), condition: .overwrite) }
    try await provider.delete([try key("e")])
    #expect(try await provider.list(prefix: "", after: nil).objects.map(\.key.rawValue) == ["a", "b"])
    var seen = first.objects.map(\.key.rawValue)
    var cursor = first.next
    while let current = cursor {
      let page = try await provider.list(prefix: "", after: current)
      seen += page.objects.map(\.key.rawValue)
      cursor = page.next
    }
    #expect(seen == ["a", "c", "d", "f"])
  }

  @Test("should bound one catch-up and finish a long enumeration over later listings")
  func boundsCatchUp() async throws {
    let graph = FakeGraph()
    graph.configure { $0.deltaPageSize = 1 }
    let harness = try OneDriveHarness(graph: graph)
    let writer = try harness.provider()
    for index in 0..<6 { _ = try await writer.put(try key("k\(index)"), data: Data([1]), condition: .overwrite) }
    let reader = try harness.provider(OneDriveProviderOptions(maxDeltaPagesPerCatchUp: 2), state: InMemoryOneDriveStateStore())
    var listings: [[String]] = []
    for _ in 0..<5 { listings.append(try await Self.keys(reader)) }
    #expect(listings.first == [])
    #expect(listings.last == (0..<6).map { "k\($0)" })
    #expect(listings.allSatisfy { $0.isEmpty || $0 == (0..<6).map { "k\($0)" } })
  }

  @Test("should empty the index when the vault folder disappears and follow the folder a later put creates")
  func followsRecreatedFolder() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("old"), data: Data([1]), condition: .overwrite)
    #expect(try await Self.keys(provider) == ["old"])
    harness.graph.deleteItem(named: OneDriveHarness.vault, in: FakeGraph.appFolderID)
    #expect(try await Self.keys(provider).isEmpty)
    let old = try key("old")
    #expect(await storageError { _ = try await provider.get(old) } == .notFound(old))
    _ = try await provider.put(try key("new"), data: Data([2]), condition: .overwrite)
    #expect(try await Self.keys(provider) == ["new"])
  }

  @Test("should list a long key another device stored, reading its key from the file header")
  func listsForeignOverflowFiles() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("seed"), data: Data(), condition: .overwrite)
    let long = try key(String(repeating: "L", count: 120))
    let folderID = try #require(harness.vaultFolderID)
    let name = OneDriveName.encode(long)
    harness.graph.seedFile(name: name, data: OneDriveKeyHeader.encode(long) + Data([5, 6, 7]), in: folderID)
    harness.graph.seedFile(name: OneDriveName.overflowName(try key("corrupt")), data: Data("garbage".utf8), in: folderID)
    #expect(try await provider.listAll(prefix: "") == [StorageObject(key: long, size: 3), StorageObject(key: try key("seed"), size: 0)])
    let read = try await provider.get(long)
    #expect(read == Data([5, 6, 7]))
    #expect(read.startIndex == 0)
    let rangeRequests = harness.graph.requests.filter { $0.url.host() == FakeGraph.downloadHost && $0.range != nil }
    #expect(rangeRequests.count == 2)
  }
}
