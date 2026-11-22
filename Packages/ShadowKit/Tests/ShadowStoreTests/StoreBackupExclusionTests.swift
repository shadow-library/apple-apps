import Foundation
import Testing

@testable import ShadowStore

@Suite("VaultStore backup exclusion")
struct StoreBackupExclusionTests {
  /// The attribute Foundation writes for `isExcludedFromBackup`; the resource value can lag its removal under load, the attribute itself cannot.
  private static let excludeItem = "com.apple.metadata:com_apple_backup_excludeItem"

  private func isExcluded(_ url: URL) throws -> Bool {
    var fresh = url
    fresh.removeAllCachedResourceValues()
    return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
  }

  private func settles(on expected: Bool, _ url: URL) async throws -> Bool {
    for _ in 0..<6_000 {
      if try isExcluded(url) == expected { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  private func open(_ directory: TemporaryDirectory) throws -> VaultStore {
    try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1)
  }

  @Test("should not exclude a new vault from backup until asked")
  func shouldStartIncluded() throws {
    let directory = TemporaryDirectory()
    _ = try open(directory)
    #expect(try !isExcluded(directory.url))
  }

  @Test("should set the flag on the vault directory and clear it again")
  func shouldSetAndClear() async throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    try store.setExcludedFromBackup(true)
    #expect(try await settles(on: true, directory.url))
    try store.setExcludedFromBackup(false)
    #expect(try await settles(on: false, directory.url))
  }

  @Test("should keep the flag when set twice")
  func shouldBeIdempotent() async throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    try store.setExcludedFromBackup(true)
    try store.setExcludedFromBackup(true)
    #expect(try await settles(on: true, directory.url))
  }

  @Test("should set the flag again on the same store after the system lost it")
  func shouldReassertAfterLoss() async throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    try store.setExcludedFromBackup(true)
    #expect(try await settles(on: true, directory.url))
    let path = directory.url.path(percentEncoded: false)
    #expect(removexattr(path, Self.excludeItem, 0) == 0)
    #expect(getxattr(path, Self.excludeItem, nil, 0, 0, 0) == -1)
    try store.setExcludedFromBackup(true)
    #expect(getxattr(path, Self.excludeItem, nil, 0, 0, 0) > 0)
    #expect(try await settles(on: true, directory.url))
  }

  @Test("should refuse to exclude a directory that holds files the vault does not own")
  func shouldRefuseSharedDirectory() async throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    try Data().write(to: directory.url.appending(path: "notes.txt"))
    let error = #expect(throws: StoreError.self) { try store.setExcludedFromBackup(true) }
    guard case .backupExclusion = error else {
      Issue.record("expected a backup exclusion error, got \(String(describing: error))")
      return
    }
    #expect(try !isExcluded(directory.url))
    try store.setExcludedFromBackup(false)
  }

  @Test("should accept the database and its write-ahead files as the only contents")
  func shouldAcceptOwnFiles() async throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false))
    #expect(names.contains("vault.sqlite"))
    try store.setExcludedFromBackup(true)
    #expect(try await settles(on: true, directory.url))
  }

  @Test("should accept the store's blob folder beside the database and refuse any other folder")
  func shouldAcceptBlobFolder() async throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    let blobs = try #require(store.blobDirectory)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    try Data("blob".utf8).write(to: blobs.appending(path: "a"))

    try store.setExcludedFromBackup(true)
    #expect(try await settles(on: true, directory.url))
    #expect(blobs.deletingLastPathComponent().standardizedFileURL == directory.url.standardizedFileURL)

    try FileManager.default.createDirectory(at: directory.url.appending(path: "other-blobs"), withIntermediateDirectories: true)
    #expect(throws: StoreError.self) { try store.setExcludedFromBackup(true) }
  }

  @Test("should ignore the request for an in-memory store")
  func shouldIgnoreInMemory() throws {
    let store = try VaultStore.open(.inMemory, registry: Fixture.v1)
    try store.setExcludedFromBackup(true)
  }

  @Test("should report a typed error when the directory is gone")
  func shouldReportMissingDirectory() throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    try FileManager.default.removeItem(at: directory.url)
    let error = #expect(throws: StoreError.self) { try store.setExcludedFromBackup(true) }
    guard case .backupExclusion = error else {
      Issue.record("expected a backup exclusion error, got \(String(describing: error))")
      return
    }
  }

  @Test("should open on macOS without failing where file protection does not apply")
  func shouldOpenWithSystemFiles() throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    #expect(FileManager.default.fileExists(atPath: directory.storeURL.path(percentEncoded: false)))
    _ = store
  }
}
