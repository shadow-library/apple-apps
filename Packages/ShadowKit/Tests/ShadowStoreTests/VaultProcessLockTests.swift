import Foundation
import Testing

@testable import ShadowStore

@Suite("VaultProcessLock")
struct VaultProcessLockTests {
  @Test("should hold a file vault's lock for one holder until it is released")
  func shouldHoldUntilReleased() throws {
    let directory = TemporaryDirectory()
    let store = try StoreFixture.open(at: .file(directory.storeURL))
    let first = try #require(try store.acquireProcessLock(.jobs))
    #expect(try store.acquireProcessLock(.jobs) == nil)
    first.release()
    first.release()
    let second = try #require(try store.acquireProcessLock(.jobs))
    #expect(try store.acquireProcessLock(.jobs) == nil)
    _ = second
  }

  @Test("should free the lock when its holder goes away")
  func shouldFreeOnDeinit() throws {
    let directory = TemporaryDirectory()
    let store = try StoreFixture.open(at: .file(directory.storeURL))
    do { _ = try #require(try store.acquireProcessLock(.jobs)) }
    #expect(try store.acquireProcessLock(.jobs) != nil)
  }

  @Test("should lock a second store opened on the same database out")
  func shouldLockOutASecondStore() throws {
    let directory = TemporaryDirectory()
    let first = try StoreFixture.open(at: .file(directory.storeURL))
    let second = try StoreFixture.open(at: .file(directory.storeURL))
    let held = try #require(try first.acquireProcessLock(.jobs))
    #expect(try second.acquireProcessLock(.jobs) == nil)
    held.release()
    #expect(try second.acquireProcessLock(.jobs) != nil)
  }

  @Test("should grant every acquire on an in-memory store")
  func shouldGrantInMemory() throws {
    let store = try StoreFixture.open()
    let first = try store.acquireProcessLock(.jobs)
    let second = try store.acquireProcessLock(.jobs)
    #expect(first != nil && second != nil)
  }

  @Test("should count the lock file as the vault's own when excluding it from backup")
  func shouldOwnTheLockFile() throws {
    let directory = TemporaryDirectory()
    let store = try StoreFixture.open(at: .file(directory.storeURL))
    let held = try #require(try store.acquireProcessLock(.jobs))
    #expect(FileManager.default.fileExists(atPath: directory.url.appending(path: "vault.sqlite-jobs.lock").path(percentEncoded: false)))
    try store.setExcludedFromBackup(true)
    try store.setExcludedFromBackup(false)
    held.release()
  }
}
