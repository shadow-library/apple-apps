import Foundation
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncCloudKit

@Suite("CloudKitStorageProvider index", TestTimeLimit.quick)
struct CloudKitIndexTests {
  @Test("should list what another device wrote and drop what it deleted, from the change feed")
  func followsTheFeed() async throws {
    let fake = FakeCloudKitZone()
    let mine = CloudKitFixture.provider(fake)
    let theirs = CloudKitFixture.provider(fake)
    _ = try await mine.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
    _ = try await theirs.put(try CloudKitFixture.key("b"), data: Data([2, 2]), condition: .overwrite)
    #expect(try await mine.listAll(prefix: "") == [StorageObject(key: try CloudKitFixture.key("a"), size: 1), StorageObject(key: try CloudKitFixture.key("b"), size: 2)])
    try await theirs.delete([try CloudKitFixture.key("a")])
    #expect(try await CloudKitFixture.keys(mine) == ["b"])
  }

  @Test("should rebuild the index when the change token expires, dropping records deleted while it was stale")
  func rebuildsAfterExpiry() async throws {
    let fake = FakeCloudKitZone()
    fake.configureLimits { $0.feedPageSize = 2 }
    let store = InMemoryCloudKitStateStore()
    let mine = CloudKitFixture.provider(fake, store: store)
    let theirs = CloudKitFixture.provider(fake)
    for raw in ["a", "b", "c", "d", "e"] { _ = try await mine.put(try CloudKitFixture.key(raw), data: Data([1]), condition: .overwrite) }
    #expect(try await CloudKitFixture.keys(mine) == ["a", "b", "c", "d", "e"])
    try await theirs.delete([try CloudKitFixture.key("b"), try CloudKitFixture.key("d")])
    _ = try await theirs.put(try CloudKitFixture.key("f"), data: Data([3]), condition: .overwrite)
    fake.expireTokens()
    let fetchesBefore = fake.callCount(.fetchChanges)
    #expect(try await CloudKitFixture.keys(mine) == ["a", "c", "e", "f"])
    #expect(fake.callCount(.fetchChanges) - fetchesBefore >= 3)
    #expect(await store.state?.entries.map(\.key.rawValue) == ["a", "c", "e", "f"])
    #expect(try await CloudKitFixture.keys(mine) == ["a", "c", "e", "f"])
  }

  @Test("should keep this device's puts and deletions made while the index is being rebuilt")
  func keepsWritesDuringRebuild() async throws {
    let fake = FakeCloudKitZone()
    let gated = GatedZone(fake)
    let provider = CloudKitStorageProvider(client: gated, stateStore: InMemoryCloudKitStateStore(), tuning: CloudKitTuning())
    for raw in ["a", "b"] { _ = try await provider.put(try CloudKitFixture.key(raw), data: Data([1]), condition: .overwrite) }
    #expect(try await CloudKitFixture.keys(provider) == ["a", "b"])
    fake.expireTokens()
    await gated.arm()
    let listing = Task { try await CloudKitFixture.keys(provider) }
    await gated.waitUntilHeld()
    _ = try await provider.put(try CloudKitFixture.key("c"), data: Data([1]), condition: .overwrite)
    try await provider.delete([try CloudKitFixture.key("a")])
    await gated.release()
    #expect(try await listing.value == ["b", "c"])
    #expect(try await CloudKitFixture.keys(provider) == ["b", "c"])
  }

  @Test("should give up when a token from a fresh read is refused at once")
  func boundsRebuilds() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    _ = try await provider.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
    fake.inject(.changeTokenExpired, on: .fetchChanges, times: 2)
    await #expect(throws: StorageError.unavailable("iCloud keeps refusing the zone's change tokens.")) { try await provider.listAll(prefix: "") }
    #expect(try await CloudKitFixture.keys(provider) == ["a"])
  }

  @Test("should save the index with its token and resume from it, trusting the saved entries")
  func resumesFromSavedState() async throws {
    let fake = FakeCloudKitZone()
    let store = InMemoryCloudKitStateStore()
    let first = CloudKitFixture.provider(fake, store: store)
    _ = try await first.put(try CloudKitFixture.key("real"), data: Data([1, 2]), condition: .overwrite)
    #expect(try await CloudKitFixture.keys(first) == ["real"])
    var saved = try #require(await store.state)
    #expect(saved.token != nil)
    #expect(saved.zoneStatus == .present)
    saved.entries.append(CloudKitIndexEntry(key: try CloudKitFixture.key("ghost"), size: 3, modified: Date(timeIntervalSince1970: 1)))
    let second = CloudKitFixture.provider(fake, store: InMemoryCloudKitStateStore(state: saved))
    #expect(try await CloudKitFixture.keys(second) == ["ghost", "real"])
    fake.expireTokens()
    #expect(try await CloudKitFixture.keys(second) == ["real"])
  }

  @Test("should ignore a saved index of another zone or container")
  func ignoresForeignState() async throws {
    let fake = FakeCloudKitZone()
    let other = try CloudKitConfiguration(containerIdentifier: "iCloud.com.shadow.apps.other")
    let foreign = CloudKitIndexState(
      configuration: other, zoneStatus: .lost(.purged), entries: [CloudKitIndexEntry(key: try CloudKitFixture.key("ghost"), size: 1, modified: Date())])
    let provider = CloudKitFixture.provider(fake, store: InMemoryCloudKitStateStore(state: foreign))
    #expect(try await provider.condition() == nil)
    #expect(try await CloudKitFixture.keys(provider).isEmpty)
  }

  @Test("should round-trip the index through its JSON file, excluded from backups, and read a damaged file as unreadable")
  func persistsToFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "cloudkit-state-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CloudKitFileStateStore(fileURL: directory.appending(path: "index.json"))
    #expect(try await store.load() == .absent)
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake, store: store)
    _ = try await provider.put(try CloudKitFixture.key("x/1"), data: Data([1]), condition: .overwrite)
    _ = try await provider.put(try CloudKitFixture.key("x/2"), data: Data([1, 2, 3]), condition: .overwrite)
    #expect(try await CloudKitFixture.keys(provider) == ["x/1", "x/2"])
    guard case .state(let loaded) = try await store.load() else {
      Issue.record("the saved index did not load")
      return
    }
    #expect(loaded.entries.map(\.size) == [1, 3])
    #expect(loaded.userRecordName == "user-1")
    #expect(loaded.belongs(to: fake.configuration))
    let excluded = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    #expect(excluded == true)
    try await store.save(loaded)
    #expect(try await store.load() == .state(loaded))
    let reopened = CloudKitFixture.provider(fake, store: CloudKitFileStateStore(fileURL: store.fileURL))
    #expect(try await CloudKitFixture.keys(reopened) == ["x/1", "x/2"])
    try Data("not json".utf8).write(to: store.fileURL)
    #expect(try await store.load() == .unreadable)
  }

  @Test("should read the zone again after an unreadable index but treat a missing zone as lost, never creating it again unasked")
  func unreadableIndexKeepsZoneSeen() async throws {
    let fake = FakeCloudKitZone()
    let writer = CloudKitFixture.provider(fake)
    _ = try await writer.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
    let reread = CloudKitFixture.provider(fake, store: InMemoryCloudKitStateStore(unreadable: true))
    #expect(try await CloudKitFixture.keys(reread) == ["a"])

    let emptied = FakeCloudKitZone()
    let lost = CloudKitFixture.provider(emptied, store: InMemoryCloudKitStateStore(unreadable: true))
    await #expect(throws: StorageError.unavailable(CloudKitZoneLoss.missing.explanation)) {
      try await lost.put(try CloudKitFixture.key("vault.json"), data: Data([1]), condition: .ifAbsent)
    }
    #expect(emptied.zoneExists == false)
    #expect(emptied.callCount(.ensureZone) == 0)
    #expect(try await lost.condition() == .zoneLost(.missing))
  }

  @Test("should ignore records of another shape and records whose name is not the hash of their path")
  func ignoresForeignRecords() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    _ = try await provider.put(try CloudKitFixture.key("kept"), data: Data([1]), condition: .overwrite)
    fake.seed(try CloudKitFixture.record(path: "kept", data: Data([9, 9, 9]), name: CloudKitRecordName("o-duplicate")))
    fake.seed(CloudKitObjectRecord(name: CloudKitRecordName("o-bad"), path: "../escape", size: 1, payload: .inline(Data([1]))))
    fake.seed(try CloudKitFixture.record(path: "elsewhere", data: Data([1]), name: CloudKitRecordLayout.recordName(of: try CloudKitFixture.key("nowhere"))))
    #expect(try await provider.listAll(prefix: "") == [StorageObject(key: try CloudKitFixture.key("kept"), size: 1)])
    #expect(try await provider.get(try CloudKitFixture.key("kept")) == Data([1]))
  }

  @Test("should list in key order across pages while the feed brings changes between them")
  func pagesStayOrdered() async throws {
    let fake = FakeCloudKitZone()
    var tuning = CloudKitTuning()
    tuning.listPageSize = 2
    let provider = CloudKitFixture.provider(fake, tuning: tuning)
    let other = CloudKitFixture.provider(fake)
    for raw in ["b", "d", "f", "h"] { _ = try await provider.put(try CloudKitFixture.key(raw), data: Data([1]), condition: .overwrite) }
    let first = try await provider.list(prefix: "", after: nil)
    #expect(first.objects.map(\.key.rawValue) == ["b", "d"])
    _ = try await other.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
    _ = try await provider.put(try CloudKitFixture.key("e"), data: Data([1]), condition: .overwrite)
    try await provider.delete([try CloudKitFixture.key("f")])
    let second = try await provider.list(prefix: "", after: first.next)
    #expect(second.objects.map(\.key.rawValue) == ["e", "h"])
    #expect(second.next == nil)
  }

  @Test("should not bring back a record this device deleted when a stale feed page still shows it, but take a newer write")
  func keepsDeletionsAgainstStalePages() async throws {
    let fake = FakeCloudKitZone()
    try await fake.ensureZone()
    let index = CloudKitIndex(client: fake, store: InMemoryCloudKitStateStore(), tuning: CloudKitTuning())
    try await index.catchUp()
    let key = try CloudKitFixture.key("gone")
    let record = try CloudKitFixture.record(path: "gone", data: Data([1]))
    guard case .success(let summary) = try await fake.save([record], mode: .overwrite)[record.name] else {
      Issue.record("the fake refused the save")
      return
    }
    try await index.recordWrite(summary, key: key)
    await index.recordDeletion(of: key)
    #expect(try await index.catchUp() == false)
    #expect(await index.page(prefix: "", after: nil).objects.isEmpty)
    _ = try await fake.save([try CloudKitFixture.record(path: "gone", data: Data([1, 2]))], mode: .overwrite)
    #expect(try await index.catchUp())
    #expect(await index.page(prefix: "", after: nil).objects == [StorageObject(key: key, size: 2)])
  }

  @Test("should coalesce concurrent listings into one catch-up and answer each in full")
  func coalescesCatchUps() async throws {
    let fake = FakeCloudKitZone()
    let gated = GatedZone(fake)
    let provider = CloudKitStorageProvider(client: gated, stateStore: InMemoryCloudKitStateStore(), tuning: CloudKitTuning())
    let writer = CloudKitFixture.provider(fake)
    for index in 0..<20 { _ = try await writer.put(try CloudKitFixture.key("k\(index)"), data: Data([1]), condition: .overwrite) }
    await gated.arm()
    let first = Task { try await CloudKitFixture.keys(provider) }
    await gated.waitUntilHeld()
    let others = (0..<7).map { _ in Task { try await CloudKitFixture.keys(provider) } }
    for _ in 0..<10_000 where await provider.index.joinedCatchUps < 7 { await Task.yield() }
    #expect(await provider.index.joinedCatchUps == 7)
    await gated.release()
    var listings = [try await first.value]
    for task in others { listings.append(try await task.value) }
    #expect(listings.allSatisfy { $0.count == 20 && $0 == $0.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } })
    #expect(fake.callCount(.fetchChanges) == 1)
  }

  @Test("should answer a page from the first key with the prefix after the cursor and stop at the first key without it")
  func pagesWithinPrefix() async throws {
    let fake = FakeCloudKitZone()
    var tuning = CloudKitTuning()
    tuning.listPageSize = 2
    let provider = CloudKitFixture.provider(fake, tuning: tuning)
    for raw in ["a/1", "b/1", "b/2", "b/3", "c/1"] { _ = try await provider.put(try CloudKitFixture.key(raw), data: Data([1]), condition: .overwrite) }
    let first = try await provider.list(prefix: "b/", after: nil)
    #expect(first.objects.map(\.key.rawValue) == ["b/1", "b/2"])
    let second = try await provider.list(prefix: "b/", after: first.next)
    #expect(second.objects.map(\.key.rawValue) == ["b/3"])
    #expect(second.next == nil)
    #expect(try await provider.list(prefix: "b/", after: ListCursor(token: "a")).objects.map(\.key.rawValue) == ["b/1", "b/2"])
    #expect(try await provider.list(prefix: "b/", after: ListCursor(token: "c")).objects.isEmpty)
  }

  @Test("should not remove an entry this device wrote while a read was finding the record missing")
  func keepsWritesDuringMissingReads() async throws {
    let fake = FakeCloudKitZone()
    let gated = GatedZone(fake)
    let provider = CloudKitStorageProvider(client: gated, stateStore: InMemoryCloudKitStateStore(), tuning: CloudKitTuning())
    let key = try CloudKitFixture.key("racing")
    _ = try await provider.put(try CloudKitFixture.key("other"), data: Data([1]), condition: .overwrite)
    await gated.arm(.fetch)
    let read = Task { try await provider.get(key) }
    await gated.waitUntilHeld()
    _ = try await provider.put(key, data: Data([2]), condition: .overwrite)
    await gated.release()
    await #expect(throws: StorageError.notFound(key)) { try await read.value }
    #expect(await provider.index.page(prefix: "", after: nil).objects.map(\.key.rawValue) == ["other", "racing"])
    #expect(try await CloudKitFixture.keys(provider) == ["other", "racing"])
  }

  @Test("should save index snapshots in the order they were taken even when an earlier save is slow")
  func serialisesSaves() async throws {
    let fake = FakeCloudKitZone()
    let store = HeldStateStore()
    let provider = CloudKitFixture.provider(fake, store: store)
    await #expect(throws: StorageError.notFound(try CloudKitFixture.key("none"))) { try await provider.get(try CloudKitFixture.key("none")) }
    await store.holdNext()
    let put = Task { try await provider.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite) }
    await store.waitUntilHeld()
    let listing = Task { try await CloudKitFixture.keys(provider) }
    for _ in 0..<10_000 where fake.callCount(.fetchChanges) == 0 { await Task.yield() }
    for _ in 0..<1_000 { await Task.yield() }
    #expect(fake.callCount(.fetchChanges) == 1)
    await store.release()
    _ = try await put.value
    _ = try await listing.value
    let saved = await store.saved
    #expect(saved.count >= 3)
    #expect(saved.last?.token != nil)
    #expect(saved.last?.zoneStatus == .present)
  }

  @Test("should yield a change notice after a push that brought changes")
  func noticesFollowPushes() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    let notices = provider.changeNotices()
    _ = try await CloudKitFixture.keys(provider)
    fake.seed(try CloudKitFixture.record(path: "pushed", data: Data([1])))
    fake.pushHint()
    #expect(await CloudKitFixture.first(notices) != nil)
    #expect(try await CloudKitFixture.keys(provider) == ["pushed"])
  }
}
