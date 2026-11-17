import Foundation
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("NovelForgeStore")
struct NovelForgeStoreTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "NovelForgeStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("should open an in-memory store whose library is empty")
  func opensInMemory() async throws {
    let store = try NovelForgeStore.openInMemory()
    let library = try await store.load(LibraryList.self)
    #expect(library.novels.isEmpty)
    #expect(library.archived.isEmpty)
    #expect(library.faults.isEmpty)
  }

  @Test("should create missing directories and reopen the same replica from a file")
  func reopensFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Vaults").appending(path: "vault.sqlite")
    let first = try NovelForgeStore.open(at: url)
    let second = try NovelForgeStore.open(at: url)
    #expect(first.replica == second.replica)
  }

  @Test("should use the Novel Forge schema version")
  func usesSchemaVersion() throws {
    #expect(NovelForgeStore.registry.version == NovelForgeSchema.version)
  }

  @Test("should throw a store error when the path is blocked by a file")
  func failsWhenBlocked() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocker = directory.appending(path: "blocker")
    try Data().write(to: blocker)
    #expect(throws: ProjectionError.self) { try NovelForgeStore.open(at: blocker.appending(path: "vault.sqlite")) }
  }
}
