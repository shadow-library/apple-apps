import Foundation
import ShadowStore
import Testing

@testable import ShadowSync

@Suite("StorageAttachment")
struct StorageAttachmentTests {
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

  private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "shadow-attach-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  @Test("should exclude the vault directory from backup on attach and include it again on detach")
  func shouldToggleExclusion() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SyncFixture.open(.file(directory.appending(path: "vault.sqlite")))
    #expect(StorageAttachment.attach(store) == nil)
    #expect(try await settles(on: true, directory))
    #expect(StorageAttachment.detach(store) == nil)
    #expect(try await settles(on: false, directory))
  }

  @Test("should re-assert the exclusion when the engine starts on a reopened vault")
  func shouldReassertOnStart() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let first = try await SyncHarness.started(store: try SyncFixture.open(location))
    #expect(try await settles(on: true, directory))
    #expect(await first.engine.backupExclusionFailure == nil)

    #expect(removexattr(directory.path(percentEncoded: false), "com.apple.metadata:com_apple_backup_excludeItem", 0) == 0)
    #expect(try await settles(on: false, directory))

    let reopened = try await SyncHarness.started(store: try SyncFixture.open(location))
    #expect(try await settles(on: true, directory))
    let failure = await reopened.engine.backupExclusionFailure
    #expect(failure == nil)
  }

  @Test("should report a failure without failing the attach")
  func shouldReportFailure() throws {
    let directory = makeDirectory()
    let store = try SyncFixture.open(.file(directory.appending(path: "vault.sqlite")))
    try FileManager.default.removeItem(at: directory)
    let failure = StorageAttachment.attach(store)
    guard case .backupExclusion = failure else {
      Issue.record("expected a backup exclusion failure, got \(String(describing: failure))")
      return
    }
  }

  @Test("should leave an in-memory vault alone")
  func shouldIgnoreInMemory() throws {
    let store = try SyncFixture.open()
    #expect(StorageAttachment.attach(store) == nil)
    #expect(StorageAttachment.detach(store) == nil)
  }
}
