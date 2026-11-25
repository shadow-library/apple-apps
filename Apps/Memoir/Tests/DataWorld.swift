import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import SwiftUI
import Testing

@testable import Memoir

/// A vault on disk in its own temporary directory, opened through the app's `VaultModel`, with sync to in-memory unrestricted storage, reminders
/// on fake notifications and this device's defaults in their own suite.
@MainActor
final class DataWorld {
  nonisolated static let day = LocalDate(isoString: "2026-11-20")!
  nonisolated static let amountMinor: Int64 = 9_007_199_254_740_993
  nonisolated static let kilograms = "81.2345"
  nonisolated static let steps = "98765"
  nonisolated static let journalText = "Walked home the long way."
  nonisolated static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])

  let directory: URL
  let location: MemoirVaultLocation
  let vault: MemoirVaultModel
  let storage = InMemoryStorageProvider(classPolicy: .unrestricted)
  let locations: SyncLocationStore
  let runtimes: SyncRuntimes
  let notifications = FakeReminderNotifications()
  let reminders: ReminderScheduler
  let rates: MemoirRates
  let dayTurns = MemoirDayTurns(center: NotificationCenter(), clockChanges: [])
  let insights: MemoirInsights
  let health = LogTesting.environment()
  let modules: MemoirModuleEffects
  let closer = BudgetPeriodCloser()
  let suite: String
  let defaults: UserDefaults
  let exports: MemoirExports
  private(set) var vaultChanges = 0

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "MemoirDataTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let location = MemoirVaultLocation.vault(try MemoirVault(directory: directory.appending(path: "Vaults", directoryHint: .isDirectory)))
    self.location = location
    vault = MemoirVaultModel(
      open: { wallClock throws(VaultOpenError) in
        do throws(MemoirVaultOpenError) {
          return try await MemoirVaultOpener.open(location, appVersion: "1", clock: MemoirClock(now: wallClock, deviceZone: { TestClock.utc }))
        } catch {
          throw error.vaultOpenError
        }
      }, hasUnlockedSinceBoot: { true })
    let storage = storage
    let keychain = InMemoryKeychain().device("phone")
    let secure = SyncSecureStores(
      ring: keychain.store(service: "com.shadow.apps.memoir.sync", scope: .synced),
      credentials: keychain.store(service: "com.shadow.apps.memoir.sync.credentials", scope: .synced),
      marker: keychain.store(service: "com.shadow.apps.memoir.sync.device", scope: .device),
      tokens: keychain.store(service: "com.shadow.apps.memoir.sync.tokens", scope: .device))
    let locations = try SyncLocationStore(url: directory.appending(path: "Sync/location.json"), outside: [directory.appending(path: "Vaults", directoryHint: .isDirectory)])
    self.locations = locations
    runtimes = SyncRuntimes(identity: .memoir) { synced, trustedClock in
      let environment = SyncStartupEnvironment(
        locationStore: locations, stores: secure, provider: { _ in storage }, hasUnlockedSinceBoot: { true }, route: synced.route,
        routedStores: synced.routedBeside)
      return SyncRuntime(
        environment: environment, store: synced.store, device: MemoirSyncWorld.device, trustedClock: trustedClock, configuration: synced.configuration,
        wallClock: SyncEngine.wallClock(preferring: trustedClock))
    }
    suite = "MemoirDataTests-\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    reminders = ReminderScheduler(notifications: notifications, setting: ReminderDeviceSetting(defaults: defaults, remindsByDefault: true), restartOn: [])
    rates = MemoirRates(client: RecordingRatesClient(), setting: RatesDeviceSetting(defaults: defaults))
    insights = MemoirInsights(ai: AIServices.memoir(defaults: defaults), trustedClock: nil)
    let health = health
    modules = MemoirModuleEffects(sync: runtimes, health: MemoirHealthImports(environment: { health }))
    exports = MemoirExports(directory: directory.appending(path: "Exports", directoryHint: .isDirectory))
  }

  func deletion(location: (@Sendable () throws(MemoirVaultOpenError) -> MemoirVaultLocation)? = nil) -> MemoirVaultDeletion {
    let fixed = self.location
    return MemoirVaultDeletion(
      vault: vault, sync: runtimes, dayTurns: dayTurns, reminders: reminders, insights: insights, rates: rates, modules: modules, closer: closer,
      location: location ?? { fixed },
      defaults: defaults, exports: exports
    ) { [weak self] in await self?.vaultChanged() }
  }

  func open() async throws -> MemoirOpenedVault {
    await vault.open()
    return try #require(vault.opened)
  }

  func vaultChanged() async {
    vaultChanges += 1
    dayTurns.follow(vault.opened)
    reminders.follow(vault.opened)
    guard let opened = vault.opened else { return }
    await runtimes.launch(MemoirSyncRoutes.vault(opened.stores), trustedClock: vault.trustedClock)
  }

  func attach(_ opened: MemoirOpenedVault) async throws {
    await runtimes.phaseChanged(.active)
    await runtimes.launch(MemoirSyncRoutes.vault(opened.stores), trustedClock: vault.trustedClock)
    let runtime = try #require(runtimes.runtime)
    let settings = SyncProviderSettings.localFolder(SyncLocalFolderSettings(url: directory.appending(path: "Storage", directoryHint: .isDirectory)))
    #expect(try await runtime.attach(settings, choice: .create).canSync)
    try await MemoirSyncWorld.until("the activity and health routes run and every store is uploaded") {
      guard runtimes.syncingRoutes.count == 2, runtimes.status == .upToDate else { return false }
      for store in [opened.stores.main, opened.stores.activity, opened.stores.restricted] where try await !MemoirSyncWorld.isUploaded(store) { return false }
      return true
    }
  }

  /// One record of each class (an expense, steps, a weight), a removed expense, a receipt whose image is here and one whose image is not, and a
  /// weekly review answer.
  @discardableResult
  func fill(_ opened: MemoirOpenedVault) async throws -> Fill {
    let stores = opened.stores
    let issuer = CommandIssuer(clock: IssueClock(timeZone: .gmt), wallClock: { Date(timeIntervalSince1970: TimeInterval(Self.day.daysSinceEpoch) * 86_400 + 43_200) })
    let source = CommandIssuerSource { _ in issuer }
    try await MetricCatalog(stores: stores, issuer: source).register(try #require(DecimalText(Self.steps)), for: BuiltinMetric.steps.reference, on: Self.day)
    _ = try await QuickLogWriter(stores: stores, issuer: source).saveWeight(try #require(DecimalText(Self.kilograms)), on: Self.day)
    let held = try await VaultBlobs(store: stores.main).put(Self.jpeg)
    let heldBlob = try #require(BlobName(held.description))
    let missingBlob = try #require(BlobName(String(repeating: "ab", count: 32)))
    let expense = UUID()
    let removed = UUID()
    let journal = UUID()
    let receipts = (held: UUID(), missing: UUID())
    let jpy = try #require(CurrencyCode("JPY"))
    let category = try #require(CategoryKey("food"))
    try await stores.store(of: .general).write { transaction in
      _ = try ExpenseRecord(id: expense, amountMinor: Self.amountMinor, currency: jpy, occurredOn: Self.day, category: category, loggedAtMillis: 1).create(in: &transaction)
      _ = try ExpenseRecord(id: removed, amountMinor: 5, currency: jpy, occurredOn: Self.day, category: category, loggedAtMillis: 2).create(in: &transaction)
      _ = try ExpenseRecord.remove(ExpenseRecord.ref(removed), in: &transaction)
      _ = try ReceiptRecord(id: receipts.held, blob: heldBlob, contentType: "image/jpeg", byteCount: Self.jpeg.count).create(in: &transaction)
      _ = try JournalEntryRecord(id: journal, date: Self.day, text: Self.journalText, mood: 3, loggedAtMillis: 3).create(in: &transaction)
      _ = try ReceiptRecord(id: receipts.missing, blob: missingBlob, contentType: "image/png", byteCount: 2048).create(in: &transaction)
    }
    try await WeeklyReviewAnswers.save("Slept before midnight", for: .better, week: Self.day, in: stores)
    try await WeeklyReviewAnswers.complete(week: Self.day, atMillis: 7, in: stores)
    return Fill(expense: expense, removedExpense: removed, journal: journal, heldBlob: held, heldReceipt: receipts.held, missingReceipt: receipts.missing)
  }

  struct Fill {
    let expense: UUID
    let removedExpense: UUID
    let journal: UUID
    let heldBlob: BlobID
    let heldReceipt: UUID
    let missingReceipt: UUID
  }

  /// Makes `folder` (relative to the world's directory) unwritable, so nothing can be added to it or removed from it.
  func lock(_ folder: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.appending(path: folder).path(percentEncoded: false))
  }

  func remove() {
    for folder in ["Sync", "Vaults"] {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appending(path: folder).path(percentEncoded: false))
    }
    if let stores = vault.opened?.stores { for kind in MemoirStoreKind.allCases { try? stores.store(kind).close() } }
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
}
