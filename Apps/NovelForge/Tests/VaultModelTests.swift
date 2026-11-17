import Foundation
import NovelForgeCore
import ShadowStore
import Synchronization
import Testing

@testable import NovelForge

@MainActor
@Suite("VaultModel")
struct VaultModelTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "NovelForgeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("should open the store in a new directory and load an empty library")
  func opensAndLoadsEmptyLibrary() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = StoreLocation.file(directory.appending(path: "Vaults").appending(path: "vault.sqlite"))
    let model = VaultModel(locate: { location })

    await model.open()

    let store = try #require(model.store)
    let library = try await store.load(LibraryList.self)
    #expect(library.novels.isEmpty)
    #expect(library.archived.isEmpty)
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Vaults").appending(path: "vault.sqlite").path(percentEncoded: false)))
  }

  @Test("should reopen the same vault with the same replica")
  func reopensSameVault() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let first = try await VaultOpener.open(location)
    let second = try await VaultOpener.open(location)
    #expect(first.replica == second.replica)
  }

  @Test("should report a failure when the vault path is blocked by a file")
  func failsWhenPathBlocked() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocker = directory.appending(path: "blocker")
    try Data().write(to: blocker)
    let model = VaultModel(locate: { .file(blocker.appending(path: "vault.sqlite")) })

    await model.open()

    #expect(model.store == nil)
    guard case .openFailed = try #require(model.failure) else {
      Issue.record("expected an open failure")
      return
    }
  }

  @Test("should report a failure when the location cannot be resolved, then recover on retry")
  func recoversAfterLocationFailure() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let attempts = Attempts()
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let model = VaultModel(locate: { () throws(VaultOpenError) -> StoreLocation in
      guard attempts.next() > 1 else { throw .locationUnavailable("no application support directory") }
      return location
    })

    await model.open()
    #expect(model.failure == .locationUnavailable("no application support directory"))

    await model.open()
    #expect(model.store != nil)
  }

  @Test("should name the vault under the bundle identifier inside Application Support")
  func resolvesDefaultLocation() throws {
    let location = try VaultOpener.defaultLocation(bundleIdentifier: "example.test")
    guard case .file(let url) = location else {
      Issue.record("expected a file location")
      return
    }
    #expect(url.pathComponents.suffix(4) == ["example.test", "Vaults", "Default", "vault.sqlite"])
  }

  @Test("should refuse a missing bundle identifier")
  func refusesMissingBundleIdentifier() {
    #expect(throws: VaultOpenError.self) { try VaultOpener.defaultLocation(bundleIdentifier: nil) }
  }
}

private nonisolated final class Attempts: Sendable {
  private let count = Mutex(0)

  func next() -> Int {
    count.withLock { value in
      value += 1
      return value
    }
  }
}
