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

/// Memoir's three stores on one device, syncing with in-memory storage whose class policy the test picks.
@MainActor
struct MemoirSyncWorld {
  static let today = LocalDate(isoString: "2026-11-20")
  static let device = ReplicaDevice(name: "Test Phone", platform: "iOS", appVersion: "1.0")

  let directory: URL
  let storage: InMemoryStorageProvider
  let stores: MemoirStores
  let runtimes: SyncRuntimes
  let clock = TrustedClock()

  init(policy: StorageClassPolicy) throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "MemoirSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let storage = InMemoryStorageProvider(classPolicy: policy)
    self.storage = storage
    let keychain = InMemoryKeychain().device("phone")
    let secure = SyncSecureStores(
      ring: keychain.store(service: "com.shadow.apps.memoir.sync", scope: .synced),
      credentials: keychain.store(service: "com.shadow.apps.memoir.sync.credentials", scope: .synced),
      marker: keychain.store(service: "com.shadow.apps.memoir.sync.device", scope: .device),
      tokens: keychain.store(service: "com.shadow.apps.memoir.sync.tokens", scope: .device))
    let locations = try SyncLocationStore(
      url: directory.appending(path: "Sync/location.json"), outside: [directory.appending(path: "Vaults/Default", directoryHint: .isDirectory)])
    stores = try MemoirStores.openInMemory(wallClock: SyncEngine.wallClock(preferring: clock))
    runtimes = SyncRuntimes(identity: .memoir) { synced, trustedClock in
      let environment = SyncStartupEnvironment(
        locationStore: locations, stores: secure, provider: { _ in storage }, hasUnlockedSinceBoot: { true }, route: synced.route,
        routedStores: synced.routedBeside)
      return SyncRuntime(
        environment: environment, store: synced.store, device: Self.device, trustedClock: trustedClock, configuration: synced.configuration,
        wallClock: SyncEngine.wallClock(preferring: trustedClock))
    }
  }

  var settings: SyncProviderSettings { .localFolder(SyncLocalFolderSettings(url: directory.appending(path: "Storage", directoryHint: .isDirectory))) }

  func attach() async throws {
    await runtimes.phaseChanged(.active)
    await runtimes.launch(MemoirSyncRoutes.vault(stores), trustedClock: clock)
    let runtime = try #require(runtimes.runtime)
    #expect(try await runtime.attach(settings, choice: .create).canSync)
    try await Self.until("the main store is up to date") { try await Self.isUploaded(stores.main) && runtimes.status == .upToDate }
  }

  /// Steps in the activity store and a weight in the health store on the day `daysBefore` today; the weight's command goes to the main store.
  func fill(daysBefore: Int = 0) async throws {
    let today = try #require(Self.today)
    let day = try #require(today.adding(days: -daysBefore))
    let issuer = CommandIssuer(clock: IssueClock(timeZone: .gmt), wallClock: { Date(timeIntervalSince1970: TimeInterval(today.daysSinceEpoch) * 86_400 + 43_200) })
    try await MetricCatalog(stores: stores, issuer: CommandIssuerSource { _ in issuer }).register(try #require(DecimalText("98765")), for: BuiltinMetric.steps.reference, on: day)
    _ = try await QuickLogWriter(stores: stores, issuer: CommandIssuerSource { _ in issuer }).saveWeight(try #require(DecimalText("81.2345")), on: day)
  }

  func steps() async throws -> [LocalDate: DecimalText] {
    let steps = MetricID<ActivityMetric>(recordUUID: BuiltinMetric.steps.id)
    return try await stores.activity.read { transaction in try MetricDays.values(of: steps, in: transaction) }
  }

  func objects(under prefix: String) async throws -> [String] {
    try await storage.listAll(prefix: prefix).map(\.key.rawValue)
  }

  func segments(under prefix: String) async throws -> [String] {
    try await objects(under: prefix).filter { $0.contains("/seg/") }
  }

  var routes: Set<String> { Set(runtimes.syncingRoutes.map(\.name)) }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  static func isUploaded(_ store: VaultStore) async throws -> Bool {
    try await store.pendingChanges(limit: 1).isEmpty
  }

  static func until(_ what: String, _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting: \(what)")
  }
}

@MainActor
@Suite("Memoir sync", TestTimeLimit.standard)
struct MemoirSyncTests {
  @Test func shouldRouteNothingBesideMainToICloudUntilActivityIsTurnedOnAndHealthNever() async throws {
    let stores = try MemoirStores.openInMemory()

    #expect(await MemoirSyncRoutes.routed(stores, policy: .iCloud).isEmpty)

    _ = try await stores.main.write { transaction in try HealthSettings.setActivityOnICloud(true, in: &transaction) }
    let on = await MemoirSyncRoutes.routed(stores, policy: .iCloud)

    #expect(on.map(\.route) == [MemoirSyncRoutes.activity])
    #expect(on.first?.store === stores.activity)
    #expect(on.first?.configuration.activityOnICloud == true)
    #expect(on.first?.title == "activity data")
  }

  @Test func shouldRouteActivityAndHealthToUnrestrictedStorageWhateverTheSetting() async throws {
    let stores = try MemoirStores.openInMemory()

    for isOn in [false, true] {
      _ = try await stores.main.write { transaction in try HealthSettings.setActivityOnICloud(isOn, in: &transaction) }
      let routed = await MemoirSyncRoutes.routed(stores, policy: .unrestricted)

      #expect(routed.map(\.route) == [MemoirSyncRoutes.activity, MemoirSyncRoutes.health])
      #expect(routed.map { $0.store === stores.activity } == [true, false])
      #expect(routed.map { $0.store === stores.restricted } == [false, true])
      #expect(routed.allSatisfy { !$0.configuration.activityOnICloud })
      #expect(routed.map(\.title) == ["activity data", "health data"])
    }
  }

  @Test func shouldDeclareBothRoutesSoTheVaultNeverMovesWithoutThem() throws {
    let stores = try MemoirStores.openInMemory()

    #expect(MemoirSyncRoutes.vault(stores).declaredRoutes == [MemoirSyncRoutes.activity, MemoirSyncRoutes.health])
  }

  @Test func shouldRaiseTheMainStoresDeclaredSchemaFloorThatThisBuildReads() throws {
    let stores = try MemoirStores.openInMemory()

    #expect(MemoirSyncRoutes.vault(stores).schemaFloor == 6)
    #expect(MemoirSchema.syncFloor <= MemoirSchema.mainRegistry.version, "a floor above this build would stop it for good")
  }

  @Test func shouldKeepTheRouteNamesOfTheStoredLayout() {
    #expect(MemoirSyncRoutes.activity.name == "activity")
    #expect(MemoirSyncRoutes.health.name == "health")
    #expect(MemoirSyncRoutes.route(for: .main) == nil)
  }

  @Test func shouldSendOnlyTheMainStoreToICloudAndKeepActivityAndHealthOnTheDevice() async throws {
    let world = try MemoirSyncWorld(policy: .iCloud)
    defer { world.remove() }
    try await world.fill()

    try await world.attach()
    try await Task.sleep(for: .milliseconds(300))

    #expect(world.routes.isEmpty)
    #expect(try await !world.segments(under: VaultPath.replicasPrefix).isEmpty)
    #expect(try await world.objects(under: "stores/").isEmpty)
    #expect(try await !MemoirSyncWorld.isUploaded(world.stores.activity))
    #expect(try await !MemoirSyncWorld.isUploaded(world.stores.restricted))
    await world.runtimes.shutDown()
  }

  @Test func shouldAttachActivityWhenTurnedOnAndDetachItWhenTurnedOffWithoutTouchingItsRecords() async throws {
    let world = try MemoirSyncWorld(policy: .iCloud)
    defer { world.remove() }
    try await world.fill()
    try await world.attach()
    let setting = ActivitySyncModel(main: world.stores.main, sync: world.runtimes)
    await setting.load()
    #expect(setting.state == .loaded(isOn: false))

    await setting.set(true)

    #expect(world.routes == ["activity"])
    try await MemoirSyncWorld.until("the activity store is uploaded") { try await MemoirSyncWorld.isUploaded(world.stores.activity) }
    #expect(try await !world.segments(under: "stores/activity/").isEmpty)
    #expect(try await world.objects(under: "stores/health/").isEmpty)
    #expect(try await !MemoirSyncWorld.isUploaded(world.stores.restricted))
    let uploaded = try await world.segments(under: "stores/activity/").count
    let held = try await world.steps()
    #expect(held.count == 1)

    await setting.set(false)

    #expect(world.routes.isEmpty)
    #expect(setting.state == .loaded(isOn: false))
    #expect(try await world.steps() == held)
    try await world.fill(daysBefore: 1)
    #expect(try await world.steps().count == 2)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await world.segments(under: "stores/activity/").count == uploaded)
    #expect(try await world.objects(under: "stores/health/").isEmpty)
    await world.runtimes.shutDown()
  }

  @Test func shouldSyncAllThreeStoresWithUnrestrictedStorage() async throws {
    let world = try MemoirSyncWorld(policy: .unrestricted)
    defer { world.remove() }
    try await world.fill()

    try await world.attach()

    #expect(world.routes == ["activity", "health"])
    try await MemoirSyncWorld.until("the activity and health stores are uploaded") {
      guard try await MemoirSyncWorld.isUploaded(world.stores.activity) else { return false }
      return try await MemoirSyncWorld.isUploaded(world.stores.restricted)
    }
    #expect(try await !world.segments(under: "stores/activity/").isEmpty)
    #expect(try await !world.segments(under: "stores/health/").isEmpty)
    await world.runtimes.shutDown()
  }
}
