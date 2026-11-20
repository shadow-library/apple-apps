import Foundation
import ShadowCore
import Testing

@testable import ShadowStore

@Suite("VaultStore always excluded from backup", TestTimeLimit.standard)
struct StoreRestrictedBackupTests {
  private static let excludeAttribute = "com.apple.metadata:com_apple_backup_excludeItem"

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

  private func open(_ directory: TemporaryDirectory, files: RecordingVaultFiles) throws -> VaultStore {
    try VaultStore.open(
      .file(directory.storeURL), registry: Fixture.v1, migrations: [], wallClock: { ManualClock.start }, reconciler: nil, backup: .alwaysExcluded, files: files)
  }

  private func open(_ directory: TemporaryDirectory) throws -> VaultStore {
    try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1, backup: .alwaysExcluded)
  }

  private func databaseExists(_ directory: TemporaryDirectory) -> Bool {
    FileManager.default.fileExists(atPath: directory.storeURL.path(percentEncoded: false))
  }

  @Test("should exclude the directory before the database file is created")
  func shouldExcludeBeforeTheDatabaseExists() throws {
    let directory = TemporaryDirectory()
    let files = RecordingVaultFiles()
    _ = try open(directory, files: files)
    #expect(files.exclusionCalls == [RecordingVaultFiles.ExclusionCall(excluded: true, contents: [])])
    #expect(databaseExists(directory))
  }

  @Test("should set the exclusion again on every reopen")
  func shouldReassertOnReopen() async throws {
    let directory = TemporaryDirectory()
    let store = try open(directory, files: RecordingVaultFiles())
    try await store.write { transaction in _ = try transaction.set(EntityRef(kind: Fixture.note, key: Fixture.key("k1")), ["title": "a"]) }
    let reopenedFiles = RecordingVaultFiles()
    let reopened = try open(directory, files: reopenedFiles)
    #expect(reopenedFiles.exclusionCalls.map(\.excluded) == [true])
    #expect(reopenedFiles.exclusionCalls.first?.contents.contains("vault.sqlite") == true)
    _ = reopened
  }

  @Test("should restore the system flag on reopen after it was lost")
  func shouldRestoreTheLostFlagOnReopen() async throws {
    let directory = TemporaryDirectory()
    _ = try open(directory)
    #expect(try await settles(on: true, directory.url))
    #expect(removexattr(directory.url.path(percentEncoded: false), Self.excludeAttribute, 0) == 0)
    #expect(try await settles(on: false, directory.url))
    _ = try open(directory)
    #expect(try await settles(on: true, directory.url))
  }

  @Test("should refuse to clear the exclusion with a typed error and never issue the change")
  func shouldRefuseClearing() throws {
    let directory = TemporaryDirectory()
    let files = RecordingVaultFiles()
    let store = try open(directory, files: files)
    let error = #expect(throws: StoreError.self) { try store.setExcludedFromBackup(false) }
    guard case .backupExclusionPinned = error else {
      Issue.record("expected the pinned exclusion error, got \(String(describing: error))")
      return
    }
    #expect(files.exclusionCalls.map(\.excluded) == [true])
    #expect(try files.isExcludedFromBackup(directory.url))
  }

  @Test("should keep the system flag when clearing is refused")
  func shouldKeepTheSystemFlagWhenRefused() async throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    #expect(try await settles(on: true, directory.url))
    #expect(throws: StoreError.self) { try store.setExcludedFromBackup(false) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(try isExcluded(directory.url))
  }

  @Test("should refuse clearing even when the directory is gone")
  func shouldRefuseClearingWithoutDirectory() throws {
    let directory = TemporaryDirectory()
    let store = try open(directory, files: RecordingVaultFiles())
    try FileManager.default.removeItem(at: directory.url)
    let error = #expect(throws: StoreError.self) { try store.setExcludedFromBackup(false) }
    guard case .backupExclusionPinned = error else {
      Issue.record("expected the pinned exclusion error, got \(String(describing: error))")
      return
    }
  }

  @Test("should accept setting the exclusion again on a pinned store")
  func shouldAcceptReassertion() throws {
    let directory = TemporaryDirectory()
    let files = RecordingVaultFiles()
    let store = try open(directory, files: files)
    try store.setExcludedFromBackup(true)
    #expect(files.exclusionCalls.map(\.excluded) == [true, true])
  }

  @Test("should refuse clearing on a pinned in-memory store")
  func shouldRefuseClearingInMemory() throws {
    let files = RecordingVaultFiles()
    let store = try VaultStore.open(.inMemory, registry: Fixture.v1, migrations: [], wallClock: { ManualClock.start }, reconciler: nil, backup: .alwaysExcluded, files: files)
    try store.setExcludedFromBackup(true)
    #expect(throws: StoreError.self) { try store.setExcludedFromBackup(false) }
    #expect(files.exclusionCalls.isEmpty)
  }

  @Test("should refuse to open in a directory holding files the vault does not own and create no database")
  func shouldRefuseSharedDirectory() throws {
    let directory = TemporaryDirectory()
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    try Data().write(to: directory.url.appending(path: "notes.txt"))
    let files = RecordingVaultFiles()
    let error = #expect(throws: StoreError.self) { try open(directory, files: files) }
    guard case .backupExclusion(let path, _) = error else {
      Issue.record("expected a backup exclusion error, got \(String(describing: error))")
      return
    }
    #expect(path == directory.url.lastPathComponent)
    #expect(files.exclusionCalls.isEmpty)
    #expect(!databaseExists(directory))
  }

  @Test("should fail the open when the exclusion cannot be set and create no database")
  func shouldFailWhenExclusionFails() throws {
    let directory = TemporaryDirectory()
    let error = #expect(throws: StoreError.self) { try open(directory, files: RecordingVaultFiles(failingExclusion: [directory.url.lastPathComponent])) }
    guard case .backupExclusion = error else {
      Issue.record("expected a backup exclusion error, got \(String(describing: error))")
      return
    }
    #expect(!databaseExists(directory))
  }

  @Test("should reopen beside its own write-ahead files and process lock")
  func shouldReopenBesideItsOwnFiles() async throws {
    let directory = TemporaryDirectory()
    let store = try open(directory)
    let lock = try #require(try store.acquireProcessLock(.jobs))
    try await store.write { transaction in _ = try transaction.set(EntityRef(kind: Fixture.note, key: Fixture.key("k1")), ["title": "a"]) }
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false))
    #expect(Set(names).isSuperset(of: ["vault.sqlite", "vault.sqlite-wal", "vault.sqlite-shm", "vault.sqlite-jobs.lock"]))
    let files = RecordingVaultFiles()
    _ = try open(directory, files: files)
    #expect(files.exclusionCalls.map(\.excluded) == [true])
    lock.release()
  }

  @Test("should keep the exclusion when many opens of one vault run at once")
  func shouldSurviveConcurrentOpens() async throws {
    let directory = TemporaryDirectory()
    let first = try open(directory)
    let url = directory.storeURL
    let opened = try await withThrowingTaskGroup(of: Bool.self) { group in
      for _ in 0..<8 {
        group.addTask {
          let store = try VaultStore.open(.file(url), registry: Fixture.v1, backup: .alwaysExcluded)
          #expect(throws: StoreError.self) { try store.setExcludedFromBackup(false) }
          return true
        }
      }
      return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
    #expect(opened == 8)
    #expect(try await settles(on: true, directory.url))
    _ = first
  }

  @Test("should leave an adjustable store's flag to its caller")
  func shouldLeaveAdjustableStoresAlone() throws {
    let directory = TemporaryDirectory()
    let files = RecordingVaultFiles()
    let store = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1, migrations: [], wallClock: { ManualClock.start }, reconciler: nil, files: files)
    #expect(files.exclusionCalls.isEmpty)
    try store.setExcludedFromBackup(true)
    try store.setExcludedFromBackup(false)
    #expect(files.exclusionCalls.map(\.excluded) == [true, false])
  }
}
