import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("Novel Forge vault")
struct VaultModelTests {
  private func vault(_ location: StoreLocation, trustedClock: TrustedClock = TrustedClock()) -> NovelForgeVault {
    NovelForgeVault(
      open: { wallClock throws(VaultOpenError) in try await VaultOpener.open(location, wallClock: wallClock) }, trustedClock: trustedClock, hasUnlockedSinceBoot: { true })
  }

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
    let model = vault(location)

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

  @Test("should stamp the vault's changes with the trusted clock it was given")
  func stampsWithTheTrustedClock() async throws {
    let clock = TrustedClock()
    let trusted = Date(timeIntervalSince1970: 2_000_000_000)
    clock.record(serverDate: trusted)
    let model = vault(.inMemory, trustedClock: clock)

    await model.open()
    let store = try #require(model.store)
    _ = try await LibraryService(store: store).create(title: "Ashfall", notes: "")

    let stamped = try #require(try await store.pendingClocks().last).date
    #expect(abs(stamped.timeIntervalSince(trusted)) < 60)
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
