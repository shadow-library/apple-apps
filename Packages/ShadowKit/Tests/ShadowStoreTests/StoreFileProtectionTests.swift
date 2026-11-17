import Foundation
import Testing

@testable import ShadowStore

@Suite("VaultStore file protection")
struct StoreFileProtectionTests {
  private static let required = FileProtectionType.completeUntilFirstUserAuthentication

  private func open(_ directory: TemporaryDirectory, files: RecordingVaultFiles) throws -> VaultStore {
    try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1, migrations: [], wallClock: { ManualClock.start }, reconciler: nil, files: files)
  }

  @Test("should protect the directory, the database and the write-ahead files with complete-until-first-authentication")
  func shouldProtectDirectoryAndDatabaseFiles() throws {
    let directory = TemporaryDirectory()
    let files = RecordingVaultFiles()
    let store = try open(directory, files: files)
    let protections = files.protectionByName()
    #expect(protections[directory.url.lastPathComponent] == Self.required)
    #expect(protections["vault.sqlite"] == Self.required)
    #expect(protections["vault.sqlite-wal"] == Self.required)
    #expect(protections["vault.sqlite-shm"] == Self.required)
    _ = store
  }

  @Test("should protect the directory before the database is created")
  func shouldProtectDirectoryFirst() throws {
    let directory = TemporaryDirectory()
    let files = RecordingVaultFiles()
    _ = try open(directory, files: files)
    #expect(files.applied.first == directory.url.lastPathComponent)
  }

  @Test("should re-assert protection on every reopen")
  func shouldReassertOnReopen() throws {
    let directory = TemporaryDirectory()
    let first = RecordingVaultFiles()
    let store = try open(directory, files: first)
    _ = store
    let second = RecordingVaultFiles()
    let reopened = try open(directory, files: second)
    #expect(second.protectionByName()["vault.sqlite"] == Self.required)
    _ = reopened
  }

  @Test("should fail the open when a database file cannot be protected")
  func shouldFailWhenProtectionFails() {
    let directory = TemporaryDirectory()
    let error = #expect(throws: StoreError.self) { try open(directory, files: RecordingVaultFiles(failing: ["vault.sqlite-wal"])) }
    guard case .fileProtection(let path, _) = error else {
      Issue.record("expected a file protection error, got \(String(describing: error))")
      return
    }
    #expect(path == "vault.sqlite-wal")
  }

  @Test("should fail the open when the directory cannot be protected")
  func shouldFailWhenDirectoryProtectionFails() {
    let directory = TemporaryDirectory()
    let error = #expect(throws: StoreError.self) { try open(directory, files: RecordingVaultFiles(failing: [directory.url.lastPathComponent])) }
    guard case .fileProtection = error else {
      Issue.record("expected a file protection error, got \(String(describing: error))")
      return
    }
  }

  @Test("should fail the open when the file reports a different protection class after it is set")
  func shouldFailWhenReadBackDiffers() {
    let directory = TemporaryDirectory()
    let error = #expect(throws: StoreError.self) { try open(directory, files: RecordingVaultFiles(readBack: FileProtectionType.none)) }
    guard case .fileProtection = error else {
      Issue.record("expected a file protection error, got \(String(describing: error))")
      return
    }
  }

  @Test("should leave files alone where protection is not enforced")
  func shouldSkipWhereNotEnforced() throws {
    let directory = TemporaryDirectory()
    let files = RecordingVaultFiles(enforcesProtection: false, failing: ["vault.sqlite"])
    let store = try open(directory, files: files)
    #expect(files.applied.isEmpty)
    _ = store
  }

  @Test("should touch nothing for an in-memory store")
  func shouldIgnoreInMemoryStores() throws {
    let files = RecordingVaultFiles(failing: ["vault.sqlite"])
    let store = try VaultStore.open(.inMemory, registry: Fixture.v1, migrations: [], wallClock: { ManualClock.start }, reconciler: nil, files: files)
    #expect(files.applied.isEmpty)
    try store.setExcludedFromBackup(true)
  }

  @Test("should describe the file protection and backup exclusion errors with stable codes")
  func shouldExposeCodes() {
    #expect(StoreError.fileProtection(path: "a", reason: "r").code == "store.file_protection")
    #expect(StoreError.backupExclusion(path: "a", reason: "r").code == "store.backup_exclusion")
  }

  @Test("should report a backup exclusion failure as a typed error")
  func shouldReportBackupFailure() throws {
    let directory = TemporaryDirectory()
    let store = try open(directory, files: RecordingVaultFiles(failingExclusion: [directory.url.lastPathComponent]))
    let error = #expect(throws: StoreError.self) { try store.setExcludedFromBackup(true) }
    guard case .backupExclusion(let path, _) = error else {
      Issue.record("expected a backup exclusion error, got \(String(describing: error))")
      return
    }
    #expect(path == directory.url.lastPathComponent)
  }
}
