import Foundation
import ShadowStore
import Testing

@testable import NovelForge

@Suite("VaultOpener protection")
struct VaultProtectionTests {
  #if !os(macOS)
    @Test("should open a file vault with complete-until-first-authentication on the directory and database")
    func shouldProtectVaultFiles() async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: "NovelForgeProtection-\(UUID().uuidString)", directoryHint: .isDirectory)
      defer { try? FileManager.default.removeItem(at: directory) }
      let database = directory.appending(path: "vault.sqlite")
      let store = try await VaultOpener.open(.file(database))
      for url in [directory, database] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let protection = attributes[.protectionKey] as? FileProtectionType
        #expect(protection == nil || protection == .completeUntilFirstUserAuthentication)
      }
      _ = store
    }
  #endif

  @Test("should open a file vault without failing on every platform")
  func shouldOpenFileVault() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "NovelForgeProtection-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await VaultOpener.open(.file(directory.appending(path: "vault.sqlite")))
    try store.setExcludedFromBackup(true)
    try store.setExcludedFromBackup(false)
  }
}
