import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("MemoirStore", TestTimeLimit.standard)
struct MemoirStoreTests {
  private func settles(on expected: Bool, _ url: URL) async throws -> Bool {
    for _ in 0..<500 {
      if BackupExclusion.isExcluded(url) == expected { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  @Test func shouldOpenTheThreeStoresInSiblingDirectoriesOfTheVaultsDirectory() throws {
    let root = try MemoirStoreFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vaults = root.appending(path: "Vaults", directoryHint: .isDirectory)
    let vault = try MemoirVault(directory: vaults)
    for store in MemoirStoreKind.allCases { _ = try MemoirStore.open(store, in: vault) }
    let expected = ["Default/vault.sqlite", "Default-activity/activity.sqlite", "Default-health/health.sqlite"]
    for (store, path) in zip(MemoirStoreKind.allCases, expected) {
      let url = vault.databaseURL(store)
      #expect(url.path(percentEncoded: false) == vaults.appending(path: path).path(percentEncoded: false))
      #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
      #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == vaults.standardizedFileURL)
    }
    let directories = try FileManager.default.contentsOfDirectory(atPath: vaults.path(percentEncoded: false)).sorted()
    #expect(directories == ["Default", "Default-activity", "Default-health"])
  }

  @Test func shouldKeepTheActivityAndHealthStoresOutOfDeviceBackupsForGood() async throws {
    let root = try MemoirStoreFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try MemoirVault(directory: root)
    for store in [MemoirStoreKind.activity, .restricted] {
      let opened = try MemoirStore.open(store, in: vault)
      let directory = vault.databaseURL(store).deletingLastPathComponent()
      #expect(try await settles(on: true, directory), "\(store.rawValue) is not excluded from backup")
      #expect(throws: StoreError.self) { try opened.setExcludedFromBackup(false) }
      do {
        try opened.setExcludedFromBackup(false)
      } catch {
        guard case .backupExclusionPinned = error else { throw MemoirFixtureError(description: "unexpected \(error)") }
      }
      #expect(BackupExclusion.isExcluded(directory))
    }
    let main = try MemoirStore.open(.main, in: vault)
    let mainDirectory = vault.databaseURL(.main).deletingLastPathComponent()
    #expect(!BackupExclusion.isExcluded(mainDirectory))
    try main.setExcludedFromBackup(true)
    #expect(try await settles(on: true, mainDirectory))
    try main.setExcludedFromBackup(false)
    #expect(try await settles(on: false, mainDirectory))
  }

  @Test func shouldReopenEachStoreAsTheSameReplicaWithItsOwnRegistry() throws {
    let root = try MemoirStoreFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try MemoirVault(directory: root, name: "Personal")
    var replicas = Set<String>()
    for store in MemoirStoreKind.allCases {
      let first = try MemoirStore.open(store, in: vault)
      let second = try MemoirStore.open(store, in: vault)
      #expect(first.replica == second.replica)
      #expect(first.registry.canonicalDescription() == store.registry.canonicalDescription())
      replicas.insert(first.replica.description)
    }
    #expect(replicas.count == MemoirStoreKind.allCases.count)
  }

  @Test func shouldStampWritesWithTheWallClockItIsGiven() async throws {
    let clock = MemoirTestClock()
    let store = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let changes = try await store.write { transaction in try QuestRecord(id: MemoirStoreFixture.quest, name: "Run").create(in: &transaction) }
    #expect(changes.first?.clock.wallMillis == Int64(clock.function().timeIntervalSince1970 * 1000))
  }

  @Test func shouldRefuseVaultNamesThatEscapeOrCollideWithAnotherVaultsStores() throws {
    let root = URL(filePath: "/tmp/vaults", directoryHint: .isDirectory)
    for name in ["Default", "Personal 2", "work_log-b"] { #expect(try MemoirVault(directory: root, name: name).name == name) }
    for name in ["", ".", "..", ".hidden", " leading", "a/b", "Café", "Default-health", "Default-HEALTH", "x-activity", String(repeating: "a", count: 65)] {
      #expect(throws: MemoirVaultError.invalidName(name)) { try MemoirVault(directory: root, name: name) }
    }
  }

  @Test func shouldThrowAStoreErrorWhenAFileBlocksTheVaultDirectory() throws {
    let root = try MemoirStoreFixture.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appending(path: "Default-health"))
    #expect(throws: StoreError.self) { try MemoirStore.open(.restricted, in: try MemoirVault(directory: root)) }
  }
}
