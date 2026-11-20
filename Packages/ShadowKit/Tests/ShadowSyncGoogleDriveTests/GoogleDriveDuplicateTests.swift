import Foundation
import ShadowSync
import Testing

@testable import ShadowSyncGoogleDrive

@Suite("GoogleDriveProvider duplicates", TestTimeLimit.quick)
struct GoogleDriveDuplicateTests {
  @Test("should converge two devices on the same winner for get, list and overwrite")
  func shouldConvergeOnOneWinner() async throws {
    let fake = FakeGoogleDrive()
    let first = try DriveFixture.provider(fake)
    let second = try DriveFixture.provider(fake)
    let key = try DriveFixture.key("replicas/r1/manifest")
    _ = try await first.list(prefix: "", after: nil)
    _ = try await second.list(prefix: "", after: nil)
    fake.setFeedLag(1000)
    _ = try await first.put(key, data: DriveFixture.bytes(10, salt: 1), condition: .overwrite)
    _ = try await second.put(key, data: DriveFixture.bytes(20, salt: 2), condition: .overwrite)
    let created = fake.files(named: key.rawValue)
    #expect(created.count == 2)

    fake.healFeed()
    #expect(try await first.listAll(prefix: "") == [StorageObject(key: key, size: 20)])
    #expect(try await second.listAll(prefix: "") == [StorageObject(key: key, size: 20)])
    #expect(try await first.get(key) == DriveFixture.bytes(20, salt: 2))
    #expect(try await second.get(key) == DriveFixture.bytes(20, salt: 2))

    _ = try await first.put(key, data: DriveFixture.bytes(30, salt: 3), condition: .overwrite)
    let remaining = fake.files(named: key.rawValue)
    #expect(remaining.map(\.id) == [created[1].id])
    #expect(remaining.first?.version == 2)
    #expect(try await second.get(key) == DriveFixture.bytes(30, salt: 3))
    #expect(try await second.listAll(prefix: "") == [StorageObject(key: key, size: 30)])
  }

  @Test("should break a modification time tie by the smallest file id on every device")
  func shouldBreakTiesById() async throws {
    let fake = FakeGoogleDrive()
    let time = Date(timeIntervalSince1970: 1_900_000_000)
    fake.insert(name: "blobs/h/0", vault: DriveFixture.vault, data: Data([2, 2]), id: "id-b", modifiedTime: time)
    fake.insert(name: "blobs/h/0", vault: DriveFixture.vault, data: Data([1]), id: "id-a", modifiedTime: time)
    let key = try DriveFixture.key("blobs/h/0")
    for provider in [try DriveFixture.provider(fake), try DriveFixture.provider(fake)] {
      #expect(try await provider.get(key) == Data([1]))
      #expect(try await provider.listAll(prefix: "blobs/") == [StorageObject(key: key, size: 1)])
    }
  }

  @Test("should update the file a lost create made rather than create a second one")
  func shouldAdoptLostCreate() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake)
    let key = try DriveFixture.key("replicas/r1/seg/1-2-a")
    fake.inject(.applyThenDrop, on: .multipart)
    let lost = await DriveFixture.error { _ = try await provider.put(key, data: Data([7]), condition: .overwrite) }
    guard case .unavailable = lost else { throw Failure("expected unavailable, got \(String(describing: lost))") }

    _ = try await provider.put(key, data: Data([7]), condition: .overwrite)
    let files = fake.files(named: key.rawValue)
    #expect(files.count == 1)
    #expect(files.first?.version == 2)
  }

  @Test("should refuse an ifAbsent put once the feed shows the key and create when it does not")
  func shouldCheckIfAbsentAgainstTheFeed() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake)
    _ = try await provider.list(prefix: "", after: nil)
    let key = try DriveFixture.key("vault.json")
    fake.insert(name: key.rawValue, vault: DriveFixture.vault, data: Data([1]))

    #expect(await DriveFixture.error { _ = try await provider.put(key, data: Data([2]), condition: .ifAbsent) } == .alreadyExists(key))
    #expect(fake.files(named: key.rawValue).map(\.data) == [Data([1])])
    let fresh = try DriveFixture.key("keys/a/b")
    _ = try await provider.put(fresh, data: Data([3]), condition: .ifAbsent)
    #expect(fake.files(named: fresh.rawValue).count == 1)
  }

  @Test("should read a surviving duplicate when the winner is gone")
  func shouldFallBackToSurvivingDuplicate() async throws {
    let fake = FakeGoogleDrive()
    let older = fake.insert(name: "base/a", vault: DriveFixture.vault, data: Data([1]))
    let newer = fake.insert(name: "base/a", vault: DriveFixture.vault, data: Data([1, 1]))
    let provider = try DriveFixture.provider(fake)
    let key = try DriveFixture.key("base/a")
    #expect(try await provider.get(key) == Data([1, 1]))
    fake.setFeedLag(1000)
    fake.remove(newer)

    #expect(try await provider.get(key) == Data([1]))
    #expect(fake.allFiles.map(\.id) == [older])
  }

  @Test("should delete every duplicate of a key")
  func shouldDeleteAllDuplicates() async throws {
    let fake = FakeGoogleDrive()
    fake.insert(name: "seg/a", vault: DriveFixture.vault, data: Data([1]))
    fake.insert(name: "seg/a", vault: DriveFixture.vault, data: Data([1]))
    fake.insert(name: "seg/b", vault: DriveFixture.vault, data: Data([2]))
    let provider = try DriveFixture.provider(fake)
    try await provider.delete([DriveFixture.key("seg/a")])

    #expect(fake.allFiles.map(\.name) == ["seg/b"])
    #expect(try await provider.listAll(prefix: "seg/").map(\.key.rawValue) == ["seg/b"])
  }
}

struct Failure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
