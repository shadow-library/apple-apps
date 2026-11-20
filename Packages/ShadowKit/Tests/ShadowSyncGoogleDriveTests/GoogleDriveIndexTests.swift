import Foundation
import ShadowSync
import Testing

@testable import ShadowSyncGoogleDrive

@Suite("GoogleDriveProvider index", TestTimeLimit.quick)
struct GoogleDriveIndexTests {
  private static func names(_ provider: GoogleDriveProvider, prefix: String = "") async throws -> [String] {
    try await provider.listAll(prefix: prefix).map(\.key.rawValue)
  }

  @Test("should take the start token before enumerating, so a file created meanwhile is not lost")
  func shouldTakeStartTokenFirst() async throws {
    let fake = FakeGoogleDrive()
    fake.insert(name: "a", vault: DriveFixture.vault, data: Data([1]))
    fake.after(.list) { fake.insert(name: "b", vault: DriveFixture.vault, data: Data([2])) }
    let provider = try DriveFixture.provider(fake)

    #expect(try await Self.names(provider) == ["a"])
    let routes = fake.requests.map(\.route)
    #expect(routes.prefix(2) == [.startPageToken, .list])
    #expect(try await Self.names(provider) == ["a", "b"])
  }

  @Test("should resume from the saved token and index without enumerating again")
  func shouldReloadPersistedState() async throws {
    let fake = FakeGoogleDrive()
    let store = InMemoryGoogleDriveStateStore()
    fake.insert(name: "a", vault: DriveFixture.vault, data: Data([1]))
    #expect(try await Self.names(DriveFixture.provider(fake, store: store)) == ["a"])
    #expect(await store.saveCount == 1)

    fake.insert(name: "b", vault: DriveFixture.vault, data: Data([2]))
    let reloaded = try DriveFixture.provider(fake, store: store)
    #expect(try await Self.names(reloaded) == ["a", "b"])
    #expect(fake.requests(.startPageToken).count == 1)
    #expect(fake.requests(.list).count == 1)
    #expect(await store.saveCount == 2)
    _ = try await Self.names(reloaded)
    #expect(await store.saveCount == 2)
  }

  @Test("should keep the index in a file that survives a restart and rebuild from a corrupt one")
  func shouldUseFileStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gdrive-index-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GoogleDriveFileStateStore(fileURL: directory.appending(path: "nested/index.json"))
    #expect(try store.load() == nil)
    let fake = FakeGoogleDrive()
    fake.insert(name: "a", vault: DriveFixture.vault, data: Data([1]))
    #expect(try await Self.names(DriveFixture.provider(fake, store: store)) == ["a"])
    let saved = try #require(try store.load())
    #expect(saved.files.map(\.key.rawValue) == ["a"])

    #expect(try await Self.names(DriveFixture.provider(fake, store: store)) == ["a"])
    #expect(fake.requests(.list).count == 1)
    try Data("not json".utf8).write(to: store.fileURL)
    #expect(try store.load() == nil)
    #expect(try await Self.names(DriveFixture.provider(fake, store: store)) == ["a"])
    #expect(fake.requests(.list).count == 2)
  }

  @Test("should ignore a saved index of another vault")
  func shouldIgnoreOtherVaultState() async throws {
    let fake = FakeGoogleDrive()
    fake.insert(name: "mine", vault: DriveFixture.vault, data: Data([1]))
    let foreign = GoogleDriveIndexState(
      vault: "Other", pageToken: "0", files: [GoogleDriveIndexedFile(id: "x", key: try DriveFixture.key("theirs"), size: 1, version: 1, modifiedTime: Date())],
      removed: [], settleAt: nil, tokenFromRebuild: false)
    let provider = try DriveFixture.provider(fake, store: InMemoryGoogleDriveStateStore(state: foreign))
    #expect(try await Self.names(provider) == ["mine"])
  }

  @Test("should rebuild the index from scratch when Drive rejects the page token")
  func shouldRebuildOnInvalidToken() async throws {
    let fake = FakeGoogleDrive()
    let gone = fake.insert(name: "gone", vault: DriveFixture.vault, data: Data([1]))
    fake.insert(name: "kept", vault: DriveFixture.vault, data: Data([2]))
    let provider = try DriveFixture.provider(fake)
    #expect(try await Self.names(provider) == ["gone", "kept"])
    #expect(try await Self.names(provider) == ["gone", "kept"])

    fake.setFeedLag(1000)
    fake.remove(gone)
    fake.insert(name: "new", vault: DriveFixture.vault, data: Data([3]))
    fake.expirePageTokens()
    #expect(try await Self.names(provider) == ["kept", "new"])
    #expect(fake.requests(.startPageToken).count == 2)
  }

  @Test("should keep an overwrite that lands while a rebuild enumerates")
  func shouldKeepWriteDuringRebuild() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake)
    let key = try DriveFixture.key("replicas/r1/manifest")
    _ = try await provider.put(key, data: Data([1]), condition: .overwrite)
    _ = try await Self.names(provider)
    fake.insert(name: "other", vault: DriveFixture.vault, data: Data([9]))
    fake.expirePageTokens()
    fake.pause(.list) { _ = try? await provider.put(key, data: Data([2, 2, 2]), condition: .overwrite) }

    let other = try DriveFixture.key("other")
    #expect(try await provider.listAll(prefix: "") == [StorageObject(key: other, size: 1), StorageObject(key: key, size: 3)])
    #expect(fake.files(named: key.rawValue).map(\.version) == [2])
    #expect(try await provider.get(key) == Data([2, 2, 2]))
  }

  @Test("should find a file search missed at the rebuild once the index settles, without dropping anything")
  func shouldSettleAfterRebuild() async throws {
    let fake = FakeGoogleDrive()
    let clock = DriveClock()
    let early = fake.insert(name: "early", vault: DriveFixture.vault, data: Data([1]))
    fake.insert(name: "seen", vault: DriveFixture.vault, data: Data([2]))
    fake.hideFromSearch(early)
    let store = InMemoryGoogleDriveStateStore()
    let provider = try DriveFixture.provider(fake, store: store, tuning: clock.tuning())
    #expect(try await Self.names(provider) == ["seen"])

    fake.showInSearch(early)
    let written = try DriveFixture.key("written")
    _ = try await provider.put(written, data: Data([3]), condition: .overwrite)
    fake.hideFromSearch(fake.files(named: "written")[0].id)
    #expect(try await Self.names(provider) == ["seen", "written"])
    #expect(fake.requests(.list).count == 1)

    clock.advance(by: 121)
    #expect(try await Self.names(provider) == ["early", "seen", "written"])
    #expect(fake.requests(.list).count == 2)
    #expect(await store.state?.settleAt == nil)
    clock.advance(by: 121)
    #expect(try await Self.names(provider) == ["early", "seen", "written"])
    #expect(fake.requests(.list).count == 2)
  }

  @Test("should keep a file the feed removed out of the settling enumeration and then forget its tombstone")
  func shouldIgnoreSearchGhostsWhenSettling() async throws {
    let fake = FakeGoogleDrive()
    let clock = DriveClock()
    let ghost = fake.insert(name: "ghost", vault: DriveFixture.vault, data: Data([1]))
    let store = InMemoryGoogleDriveStateStore()
    let provider = try DriveFixture.provider(fake, store: store, tuning: clock.tuning())
    #expect(try await Self.names(provider) == ["ghost"])

    fake.removeKeepingSearch(ghost)
    #expect(try await Self.names(provider).isEmpty)
    clock.advance(by: 121)
    #expect(try await Self.names(provider).isEmpty)
    #expect(fake.requests(.list).count == 2)
    #expect(await store.state?.removed == [])
  }

  @Test("should settle after a restart when the rebuild that needs it was saved")
  func shouldSettleAfterRestart() async throws {
    let fake = FakeGoogleDrive()
    let clock = DriveClock()
    let early = fake.insert(name: "early", vault: DriveFixture.vault, data: Data([1]))
    fake.hideFromSearch(early)
    let store = InMemoryGoogleDriveStateStore()
    #expect(try await Self.names(DriveFixture.provider(fake, store: store, tuning: clock.tuning())).isEmpty)
    #expect(await store.state?.settleAt != nil)

    fake.showInSearch(early)
    clock.advance(by: 300)
    #expect(try await Self.names(DriveFixture.provider(fake, store: store, tuning: clock.tuning())) == ["early"])
  }

  @Test("should surface an error, also after a restart, when Drive rejects the token a rebuild just took")
  func shouldStopRebuildingOnFreshTokenRejection() async throws {
    let fake = FakeGoogleDrive()
    let store = InMemoryGoogleDriveStateStore()
    #expect(try await Self.names(DriveFixture.provider(fake, store: store)).isEmpty)
    fake.inject(.status(404, reason: "notFound"), on: .changes, times: 3)
    let expected = StorageError.unavailable("Google Drive keeps rejecting new change tokens; the index is rebuilt again later.")

    let provider = try DriveFixture.provider(fake, store: store)
    for _ in 0..<2 { #expect(await DriveFixture.error { _ = try await provider.list(prefix: "", after: nil) } == expected) }
    #expect(await DriveFixture.error { _ = try await DriveFixture.provider(fake, store: store).list(prefix: "", after: nil) } == expected)
    #expect(fake.requests(.startPageToken).count == 1)
    #expect(fake.requests(.list).count == 1)
  }

  @Test("should rebuild again after a doubling backoff when a rebuilt token was invalidated, and reset the backoff once the feed works")
  func shouldRetryRebuildAfterBackoff() async throws {
    let fake = FakeGoogleDrive()
    let clock = DriveClock()
    let store = InMemoryGoogleDriveStateStore()
    let held = StorageError.unavailable("Google Drive keeps rejecting new change tokens; the index is rebuilt again later.")
    #expect(try await Self.names(DriveFixture.provider(fake, store: store, tuning: clock.tuning())).isEmpty)
    fake.insert(name: "a", vault: DriveFixture.vault, data: Data([1]))
    fake.expirePageTokens()

    let first = try DriveFixture.provider(fake, store: store, tuning: clock.tuning())
    #expect(await DriveFixture.error { _ = try await first.list(prefix: "", after: nil) } == held)
    #expect(await store.state?.rebuildBackoff == 3600)
    clock.advance(by: 1800)
    let restarted = try DriveFixture.provider(fake, store: store, tuning: clock.tuning())
    #expect(await DriveFixture.error { _ = try await restarted.list(prefix: "", after: nil) } == held)
    #expect(fake.requests(.list).count == 1)
    clock.advance(by: 1801)
    #expect(try await Self.names(restarted) == ["a"])
    #expect(fake.requests(.list).count == 2)

    fake.insert(name: "b", vault: DriveFixture.vault, data: Data([2]))
    fake.expirePageTokens()
    #expect(await DriveFixture.error { _ = try await restarted.list(prefix: "", after: nil) } == held)
    #expect(await store.state?.rebuildBackoff == 7200)
    clock.advance(by: 3600)
    #expect(await DriveFixture.error { _ = try await restarted.list(prefix: "", after: nil) } == held)
    clock.advance(by: 3601)
    #expect(try await Self.names(restarted) == ["a", "b"])
    #expect(try await Self.names(restarted) == ["a", "b"])
    #expect(await store.state?.rebuildBackoff == nil)
    #expect(await store.state?.rebuildBlockedUntil == nil)
  }

  @Test("should rebuild once on a bad request from the feed and then report it, also after a restart")
  func shouldBoundRebuildsOnBadRequests() async throws {
    let fake = FakeGoogleDrive()
    let store = InMemoryGoogleDriveStateStore()
    let provider = try DriveFixture.provider(fake, store: store)
    #expect(try await Self.names(provider).isEmpty)
    #expect(try await Self.names(provider).isEmpty)
    fake.inject(.status(400, reason: "badRequest"), on: .changes, times: 4)
    let expected = StorageError.unavailable("Google Drive keeps rejecting new change tokens; the index is rebuilt again later.")

    #expect(try await Self.names(provider).isEmpty)
    for _ in 0..<2 { #expect(await DriveFixture.error { _ = try await provider.list(prefix: "", after: nil) } == expected) }
    #expect(await DriveFixture.error { _ = try await DriveFixture.provider(fake, store: store).list(prefix: "", after: nil) } == expected)
    #expect(fake.requests(.startPageToken).count == 2)
    #expect(fake.requests(.list).count == 2)
  }

  @Test("should save the index when other devices change it and only now and then for its own writes")
  func shouldThrottleOwnWriteSaves() async throws {
    let fake = FakeGoogleDrive()
    let clock = DriveClock()
    let store = InMemoryGoogleDriveStateStore()
    let provider = try DriveFixture.provider(fake, store: store, tuning: clock.tuning())
    #expect(try await Self.names(provider).isEmpty)
    #expect(await store.saveCount == 1)

    for index in 0..<5 { _ = try await provider.put(DriveFixture.key("seg/\(index)"), data: Data([1]), condition: .overwrite) }
    #expect(try await Self.names(provider).count == 5)
    #expect(await store.saveCount == 2)
    #expect(await store.state?.tokenFromRebuild == false)

    fake.insert(name: "remote", vault: DriveFixture.vault, data: Data([2]))
    #expect(try await Self.names(provider).count == 6)
    #expect(await store.saveCount == 3)

    _ = try await provider.put(DriveFixture.key("seg/5"), data: Data([1]), condition: .overwrite)
    #expect(try await Self.names(provider).count == 7)
    #expect(await store.saveCount == 3)
    clock.advance(by: 601)
    #expect(try await Self.names(provider).count == 7)
    #expect(await store.saveCount == 4)

    let reloaded = try DriveFixture.provider(fake, store: store, tuning: clock.tuning())
    #expect(try await Self.names(reloaded).count == 7)
  }

  @Test("should drop removed and trashed files from the index")
  func shouldDropRemovedAndTrashed() async throws {
    let fake = FakeGoogleDrive()
    let removed = fake.insert(name: "x", vault: DriveFixture.vault, data: Data([1]))
    let trashed = fake.insert(name: "y", vault: DriveFixture.vault, data: Data([2]))
    let provider = try DriveFixture.provider(fake)
    #expect(try await Self.names(provider) == ["x", "y"])

    fake.remove(removed)
    fake.trash(trashed)
    #expect(try await Self.names(provider).isEmpty)
    let key = try DriveFixture.key("y")
    #expect(await DriveFixture.error { _ = try await provider.get(key) } == .notFound(key))
  }

  @Test("should never list a file of another vault, without vault properties or with a name that is not a key")
  func shouldNeverInvent() async throws {
    let fake = FakeGoogleDrive()
    fake.insert(name: "mine", vault: DriveFixture.vault, data: Data([1]))
    fake.insert(name: "theirs", vault: "Other", data: Data([1]))
    fake.insert(name: "bare", vault: nil, data: Data([1]))
    fake.insert(name: "not a key", vault: DriveFixture.vault, data: Data([1]))
    fake.insert(name: "/leading", vault: DriveFixture.vault, data: Data([1]))
    let provider = try DriveFixture.provider(fake)
    #expect(try await Self.names(provider) == ["mine"])
    fake.insert(name: "theirs-later", vault: "Other", data: Data([1]))
    #expect(try await Self.names(provider) == ["mine"])
    let theirs = try DriveFixture.key("theirs")
    #expect(await DriveFixture.error { _ = try await provider.get(theirs) } == .notFound(theirs))
  }

  @Test("should continue after the cursor key without repeating or skipping keys")
  func shouldKeepCursorStable() async throws {
    let fake = FakeGoogleDrive()
    for name in ["k1", "k2", "k3", "k4", "k5", "k6"] { fake.insert(name: name, vault: DriveFixture.vault, data: Data([1])) }
    var tuning = GoogleDriveTuning()
    tuning.listPageSize = 3
    let provider = try DriveFixture.provider(fake, tuning: tuning)
    let first = try await provider.list(prefix: "k", after: nil)
    #expect(first.objects.map(\.key.rawValue) == ["k1", "k2", "k3"])
    #expect(first.next == ListCursor(token: "k3"))

    try await provider.delete([DriveFixture.key("k1")])
    _ = try await provider.put(DriveFixture.key("k0"), data: Data([2]), condition: .overwrite)
    _ = try await provider.put(DriveFixture.key("k35"), data: Data([2]), condition: .overwrite)
    let second = try await provider.list(prefix: "k", after: first.next)
    #expect(second.objects.map(\.key.rawValue) == ["k35", "k4", "k5"])
    let third = try await provider.list(prefix: "k", after: second.next)
    #expect(third.objects.map(\.key.rawValue) == ["k6"])
    #expect(third.next == nil)
  }

  @Test("should follow a long feed in bounded catch-ups across listings")
  func shouldBoundCatchUp() async throws {
    let fake = FakeGoogleDrive()
    var tuning = GoogleDriveTuning()
    tuning.drivePageSize = 2
    tuning.catchUpPages = 2
    let provider = try DriveFixture.provider(fake, tuning: tuning)
    #expect(try await Self.names(provider).isEmpty)
    for index in 0..<10 { fake.insert(name: "f\(index)", vault: DriveFixture.vault, data: Data([1])) }

    var counts: [Int] = []
    for _ in 0..<3 { counts.append(try await Self.names(provider).count) }
    #expect(counts == [4, 8, 10])
  }
}
