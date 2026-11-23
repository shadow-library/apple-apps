import Foundation
import MemoirCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import Memoir

@Suite("MemoirVaultOpener", TestTimeLimit.standard)
struct MemoirVaultOpenerTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "MemoirTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  @Test("should open the three stores side by side under Vaults with the activity and health stores excluded from backup")
  func opensThreeStores() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaults = directory.appending(path: "Vaults", directoryHint: .isDirectory)

    _ = try await MemoirVaultOpener.open(.vault(try MemoirVault(directory: vaults)), appVersion: "1")

    #expect(exists(vaults.appending(path: "Default/vault.sqlite")))
    #expect(exists(vaults.appending(path: "Default-activity/activity.sqlite")))
    #expect(exists(vaults.appending(path: "Default-health/health.sqlite")))
    #expect(!BackupExclusion.isExcluded(vaults.appending(path: "Default", directoryHint: .isDirectory)))
    #expect(BackupExclusion.isExcluded(vaults.appending(path: "Default-activity", directoryHint: .isDirectory)))
    #expect(BackupExclusion.isExcluded(vaults.appending(path: "Default-health", directoryHint: .isDirectory)))
  }

  @Test("should reopen the same vault with the same replicas")
  func reopensSameVault() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = try MemoirVault(directory: directory)

    let first = try await MemoirVaultOpener.open(.vault(vault), appVersion: "1")
    let second = try await MemoirVaultOpener.open(.vault(vault), appVersion: "2")

    #expect(first.stores.main.replica == second.stores.main.replica)
    #expect(first.stores.activity.replica == second.stores.activity.replica)
    #expect(first.stores.restricted.replica == second.stores.restricted.replica)
  }

  @Test("should run the projection when the vault opens, so derived reads find their tables")
  func projectsOnOpen() async throws {
    let opened = try await MemoirVaultOpener.open(.inMemory, appVersion: "1")

    let hero = try await opened.stores.main.read { transaction in try MemoirDerived.hero(in: transaction) }

    #expect(hero != nil)
  }

  @Test("should walk the derived day to the account's day in its zone, and in the staged zone once that day has passed, only when the day is refreshed")
  func walksTheHorizonInTheAccountZone() async throws {
    let clock = TestClock(day: 0, minute: 720)
    let opened = try await MemoirVaultOpener.open(.inMemory, appVersion: "1", clock: clock.memoir(deviceZone: TestClock.berlin))
    let writer = MemoirScreenContext(opened).writer
    try await writer.issue(try TestQuests.zone("UTC"))
    let quest = QuestRecord(id: UUID(), name: "Walk")
    try await writer.issue(try TestQuests.creation(quest.id), creating: quest)
    try await writer.issue(try TestQuests.zone("Asia/Tokyo"))
    #expect(try await opened.stores.openDay() == TestClock.day(0))

    clock.set(day: 0, minute: 23 * 60 + 30)
    try await opened.refreshDay()
    #expect(try await opened.stores.openDay() == TestClock.day(0), "the device's Berlin is on the next day; the account's UTC is not")

    clock.set(day: 1, minute: 15 * 60 + 30)
    #expect(try await opened.stores.openDay() == TestClock.day(0), "nothing walks the view before the refresh")
    try await opened.refreshDay()

    #expect(try await opened.stores.openDay() == TestClock.day(2), "half past midnight in Tokyo, which took over on day 1")
    let zone = try await AccountZone.load(from: opened.stores.main)
    #expect(zone.inForce == "Asia/Tokyo" && zone.staged == nil)
  }

  @Test("should fail with a typed open failure when a file blocks the vault's directory")
  func failsWhenPathBlocked() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocker = directory.appending(path: "Vaults")
    try Data().write(to: blocker)

    await #expect {
      _ = try await MemoirVaultOpener.open(.vault(try MemoirVault(directory: blocker)), appVersion: "1")
    } throws: { error in
      guard case .openFailed = error as? MemoirVaultOpenError else { return false }
      return true
    }
  }

  @Test("should place the default vault under the bundle's Vaults directory")
  func placesDefaultVault() throws {
    let vault = try MemoirVaultOpener.defaultVault(bundleIdentifier: "com.shadow.apps.memoir")

    #expect(vault.name == MemoirVault.defaultName)
    #expect(vault.directory.pathComponents.suffix(2) == ["com.shadow.apps.memoir", "Vaults"])
    #expect(vault.databaseURL(.restricted).pathComponents.suffix(4) == ["com.shadow.apps.memoir", "Vaults", "Default-health", "health.sqlite"])
  }

  @Test("should refuse a missing bundle identifier as an unavailable location")
  func refusesMissingBundleIdentifier() {
    #expect(throws: MemoirVaultOpenError.locationUnavailable("the app has no bundle identifier")) {
      try MemoirVaultOpener.defaultVault(bundleIdentifier: nil)
    }
  }

  @Test("should read the build number and refuse a bundle without one")
  func readsBuildVersion() throws {
    #expect(try MemoirVaultOpener.buildVersion(of: ["CFBundleVersion": "42", "CFBundleShortVersionString": "1.0.0"]) == "42")
    #expect(throws: MemoirVaultOpenError.buildVersionUnavailable) { try MemoirVaultOpener.buildVersion(of: ["CFBundleShortVersionString": "1.0.0"]) }
    #expect(throws: MemoirVaultOpenError.buildVersionUnavailable) { try MemoirVaultOpener.buildVersion(of: ["CFBundleVersion": ""]) }
    #expect(throws: MemoirVaultOpenError.buildVersionUnavailable) { try MemoirVaultOpener.buildVersion(of: nil) }
  }
}
