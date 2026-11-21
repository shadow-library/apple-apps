import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Metric class isolation", TestTimeLimit.standard)
struct ClassIsolationTests {
  private static let healthValues = ["81.2345", "53.0917", "Glucosamine Xq", "6.4321"]
  private static let activityValues = ["98765", "4321.77"]
  private static let generalMarkers = ["Marker Quest Zq", "Pages Marker Zq"]

  private struct Engine {
    let engine: SyncEngine
    let provider: InMemoryStorageProvider
  }

  private func engine(_ store: VaultStore, configuration: SyncConfiguration, provider: InMemoryStorageProvider = InMemoryStorageProvider(classPolicy: .iCloud))
    async throws -> Engine
  {
    let keychain = InMemoryKeychain()
    let device = keychain.device("phone")
    let vault = try #require(VaultID("memoir-class-isolation"))
    let ring = KeyRing(vault: vault, store: device.store(service: "keys", scope: .synced))
    _ = try ring.createKey()
    let lifecycle = ReplicaLifecycle(
      store: store, vault: vault, marker: DeviceMarker(store: device.store(service: "marker", scope: .device)),
      device: ReplicaDevice(name: "phone", platform: "test", appVersion: "1"))
    let engine = SyncEngine(store: store, provider: provider, vault: vault, ring: ring, lifecycle: lifecycle, trustedClock: TrustedClock(), configuration: configuration)
    _ = try await engine.start()
    return Engine(engine: engine, provider: provider)
  }

  private func files(of store: MemoirStoreKind, in vault: MemoirVault) -> [URL] {
    let database = vault.databaseURL(store)
    return ["", "-wal", "-shm"].map { URL(fileURLWithPath: database.path(percentEncoded: false) + $0) }
  }

  private func found(_ values: [String], in urls: [URL]) throws -> [String] {
    var bytes = Data()
    for url in urls { bytes.append(try Self.contents(of: url)) }
    return values.filter { bytes.range(of: Data($0.utf8)) != nil }
  }

  private static func contents(of url: URL) throws -> Data {
    var attempt = 0
    while true {
      do {
        return try Data(contentsOf: url, options: .uncached)
      } catch {
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return Data() }
        attempt += 1
        if attempt == 5 { throw error }
        Thread.sleep(forTimeInterval: 0.02 * Double(attempt))
      }
    }
  }

  private func filled() async throws -> MemoirStores {
    let stores = try MemoirStores.openInMemory()
    try await fill(stores)
    return stores
  }

  private func fill(_ stores: MemoirStores) async throws {
    let reader = FakeHealthReader()
    let today = HealthFixture.today
    let morning = HealthFixture.midnight(today) + 7 * HealthFixture.hour
    reader.setTotal(.stepCount, HealthFixture.decimal("98765"), on: today)
    reader.add(.bodyMass, [HealthSample(id: UUID(), startMillis: morning, endMillis: morning, utcOffsetMinutes: 0, quantity: HealthFixture.decimal("81.2345"))])
    reader.add(.restingHeartRate, [HealthSample(id: UUID(), startMillis: morning, endMillis: morning, utcOffsetMinutes: 0, quantity: HealthFixture.decimal("53.0917"))])
    _ = try await HealthFixture.claim(HealthFixture.phone, in: stores)
    _ = try await HealthImport(reader: reader, stores: stores, device: HealthFixture.phone, clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()).run()

    let catalog = MetricCatalog(stores: stores, issuer: CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()))
    let glucose = try await catalog.create(MetricDefinition(name: "Glucosamine Xq", unit: "mmol/L", valueType: .number, direction: .range))
    try await catalog.register(HealthFixture.decimal("6.4321"), for: glucose, on: today)
    try await catalog.register(HealthFixture.decimal("4321.77"), for: BuiltinMetric.steps.reference, on: today.adding(days: -1)!)
    try await QuestThresholds.set(
      QuestThreshold(quest: MemoirStoreFixture.quest, metric: glucose, value: HealthFixture.decimal("6.4321"), comparison: .atMost), in: stores)
    _ = try await QuickLogWriter(stores: stores, issuer: catalog.issuer).saveWeight(HealthFixture.decimal("81.2345"), on: today.adding(days: -2)!)
    _ = try await stores.main.write { transaction in try QuestRecord(id: MemoirStoreFixture.quest, name: "Marker Quest Zq").create(in: &transaction) }
    let pages = try await catalog.create(MetricDefinition(name: "Pages Marker Zq", valueType: .count, direction: .higher), as: .general)
    try await catalog.register(HealthFixture.decimal("12"), for: pages, on: today)
  }

  @Test func shouldKeepHealthAndActivityValuesOutOfTheMainStoreFilesWhicheverTheActivitySetting() async throws {
    for activityOnICloud in [false, true] {
      let root = try MemoirStoreFixture.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let vault = try MemoirVault(directory: root)
      let stores = try MemoirStores.open(in: vault)
      _ = try await stores.main.write { transaction in try HealthSettings.setActivityOnICloud(activityOnICloud, in: &transaction) }

      try await fill(stores)

      #expect(FileManager.default.fileExists(atPath: vault.databaseURL(.main).path(percentEncoded: false)))
      #expect(try found(Self.generalMarkers, in: files(of: .main, in: vault)) == Self.generalMarkers)
      #expect(try found(Self.healthValues + Self.activityValues, in: files(of: .main, in: vault)) == [])
      #expect(try found(Self.healthValues, in: files(of: .activity, in: vault)) == [])
      #expect(try found(Self.activityValues, in: files(of: .restricted, in: vault)) == [])
      #expect(try found(Self.activityValues, in: files(of: .activity, in: vault)) == Self.activityValues)
      #expect(try found(Self.healthValues, in: files(of: .restricted, in: vault)) == Self.healthValues)
      let types = try await stores.main.read { transaction in try MemoirCommand.listing(in: transaction) }.entries.map(\.record.type.name).sorted()
      #expect(types == ["metric.create", "metric.create", "metric.register", "weight.save"])
    }
  }

  @Test func shouldRouteOnlyTheMainStoreToICloudUntilTheOwnerTurnsActivityOn() async throws {
    let stores = try MemoirStores.openInMemory()
    #expect(try await MemoirSyncRouting.routes(for: .iCloud, settingsIn: stores.main).map(\.store) == [.main])
    _ = try await stores.main.write { transaction in try HealthSettings.setActivityOnICloud(true, in: &transaction) }
    let on = try await MemoirSyncRouting.routes(for: .iCloud, settingsIn: stores.main)
    #expect(on.map(\.store) == [.main, .activity])
    #expect(on.map(\.configuration.activityOnICloud) == [false, true])
    _ = try await stores.main.write { transaction in try HealthSettings.setActivityOnICloud(false, in: &transaction) }
    #expect(try await MemoirSyncRouting.routes(for: .iCloud, settingsIn: stores.main).map(\.store) == [.main])
    let elsewhere = try await MemoirSyncRouting.routes(for: .unrestricted, settingsIn: stores.main)
    #expect(elsewhere.map(\.store) == [.main, .activity, .restricted])
    #expect(elsewhere.allSatisfy { !$0.configuration.activityOnICloud })
  }

  @Test func shouldUploadActivityToICloudOnlyWhenTheSettingIsOnAndHealthNever() async throws {
    let off = MemoirSyncRouting.routes(for: .iCloud, activityOnICloud: false)
    let on = MemoirSyncRouting.routes(for: .iCloud, activityOnICloud: true)
    let closed = try #require(off.first { $0.store == .main }).configuration
    let admitting = try #require(on.first { $0.store == .activity }).configuration

    let refusing = try await engine(try await filled().activity, configuration: closed)
    let error = await #expect(throws: SyncError.self) { try await refusing.engine.upload() }
    guard case .syncClassRefused(_, .activity)? = error else { throw MemoirFixtureError(description: "expected syncClassRefused, got \(String(describing: error))") }
    #expect(refusing.provider.callCounts.put == 0)

    let activity = try await filled().activity
    let uploading = try await engine(activity, configuration: admitting)
    guard case .uploaded = try await uploading.engine.upload() else { throw MemoirFixtureError(description: "the activity store uploaded nothing") }
    #expect(uploading.provider.callCounts.put > 0)
    #expect(try await activity.pendingChanges(limit: .max).isEmpty)

    for configuration in [closed, admitting] {
      let health = try await engine(try await filled().restricted, configuration: configuration)
      let refusal = await #expect(throws: SyncError.self) { try await health.engine.upload() }
      guard case .syncClassRefused(_, .health)? = refusal else { throw MemoirFixtureError(description: "expected syncClassRefused, got \(String(describing: refusal))") }
      let compaction = await #expect(throws: SyncError.self) { try await health.engine.compact(force: true) }
      guard case .syncClassRefused(_, .health)? = compaction else { throw MemoirFixtureError(description: "expected syncClassRefused, got \(String(describing: compaction))") }
      #expect(health.provider.callCounts.put == 0)
    }

    let main = try await engine(try await filled().main, configuration: closed)
    guard case .uploaded = try await main.engine.upload() else { throw MemoirFixtureError(description: "the main store uploaded nothing") }
  }
}
