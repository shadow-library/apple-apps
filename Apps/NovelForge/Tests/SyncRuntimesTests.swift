import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import SwiftUI
import Synchronization
import Testing

@testable import NovelForge

/// A sync world on one device: its files under a temporary directory, its keychain in memory and a local folder as the storage.
@MainActor
struct SyncWorld {
  nonisolated static let device = ReplicaDevice(name: "Test Mac", platform: "macOS", appVersion: "1.0")

  let directory: URL
  let folder: URL
  let wiring: SyncWiring
  let provider: CountingProvider

  init(cloudKit: CloudKitAccess? = nil) throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "NovelForgeSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    folder = directory.appending(path: "Storage", directoryHint: .isDirectory)
    let support = directory.appending(path: "Application Support", directoryHint: .isDirectory)
    let paths = SyncPaths(
      applicationSupport: support, bundleIdentifier: "com.shadow.apps.novelforge.tests",
      vaultDirectory: support.appending(path: "com.shadow.apps.novelforge.tests/Vaults/Default", directoryHint: .isDirectory))
    let keychain = InMemoryKeychain().device("mac")
    let stores = SyncSecureStores(
      ring: keychain.store(service: "\(SyncWiring.app).sync", scope: .synced), credentials: keychain.store(service: "\(SyncWiring.app).sync.credentials", scope: .synced),
      marker: keychain.store(service: "\(SyncWiring.app).sync.device", scope: .device), tokens: keychain.store(service: "\(SyncWiring.app).sync.tokens", scope: .device))
    wiring = SyncWiring(paths: paths, stores: stores, cloudKit: cloudKit, device: Self.device)
    provider = try CountingProvider(root: folder)
  }

  var settings: SyncProviderSettings { .localFolder(SyncLocalFolderSettings(url: folder)) }

  /// Runtimes whose local folder is counted; every other provider comes from the app's own wiring.
  func runtimes(background: @escaping SyncBackgroundWork.Runner = SyncBackgroundWork.system, activationInterval: Duration = .seconds(60)) -> SyncRuntimes {
    let (wiring, provider, folder) = (wiring, provider, folder)
    return SyncRuntimes(
      factory: { store, trustedClock in
        guard var environment = try? wiring.environment() else { return nil }
        environment.provider = { settings throws(StorageError) in
          if case .localFolder(let local) = settings, local.path == SyncLocalFolderSettings(url: folder).path { return provider }
          return try wiring.provider(for: settings)
        }
        return SyncRuntime(
          environment: environment, store: store, device: wiring.device, trustedClock: trustedClock, wallClock: SyncEngine.wallClock(preferring: trustedClock))
      }, background: background, activationInterval: activationInterval)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  static func openStore() throws -> (VaultStore, TrustedClock) {
    let clock = TrustedClock()
    return (try NovelForgeStore.openInMemory(wallClock: SyncEngine.wallClock(preferring: clock)), clock)
  }

  static func writeNovel(_ title: String, in store: VaultStore) async throws {
    _ = try await LibraryService(store: store).create(title: title, notes: "")
  }

  /// Well inside the 45 s download poll, so a change seen here came from the trigger under test.
  static func until(_ what: String, within limit: Duration = .seconds(10), _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting: \(what)")
  }

  static func isUploaded(_ store: VaultStore) async throws -> Bool {
    try await store.pendingChanges(limit: 1).isEmpty
  }
}

/// A local folder that counts its listings, which every catch-up and download makes.
nonisolated final class CountingProvider: StorageProvider {
  let inner: LocalFolderProvider
  private let lists = Mutex(0)

  init(root: URL) throws {
    inner = try LocalFolderProvider(root: root)
  }

  var capabilities: StorageCapabilities { inner.capabilities }
  var listings: Int { lists.withLock(\.self) }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    lists.withLock { $0 += 1 }
    return try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data { try await inner.get(key) }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) { try await inner.delete(keys) }

  func changeNotices() -> AsyncStream<Void> { inner.changeNotices() }

  func segments() async throws -> [ObjectKey] {
    try await inner.list(prefix: VaultPath.replicasPrefix, after: nil).objects.map(\.key).filter { $0.rawValue.contains("/seg/") }
  }
}

@MainActor
final class BackgroundTasks {
  private(set) var names: [String] = []

  var runner: SyncBackgroundWork.Runner {
    { name, work in
      self.names.append(name)
      await work()
    }
  }
}

@MainActor
@Suite("Sync runtimes", TestTimeLimit.standard)
struct SyncRuntimesTests {
  private static func attached(_ world: SyncWorld, _ runtimes: SyncRuntimes) async throws -> (VaultStore, SyncRuntime) {
    let (store, clock) = try SyncWorld.openStore()
    await runtimes.phaseChanged(.active)
    await runtimes.launch(store, trustedClock: clock)
    let runtime = try #require(runtimes.runtime)
    #expect(try await runtime.attach(world.settings, choice: .create).canSync)
    try await SyncWorld.until("the attached vault is up to date") { runtimes.status == .upToDate }
    await runtime.changeNotice()
    try await SyncWorld.until("the runs that attaching asked for are done") { runtimes.status == .upToDate }
    return (store, runtime)
  }

  @Test func shouldLaunchOneRuntimeThatStaysOffAndTouchesNothingWhileNoLocationIsAttached() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes()
    let (store, clock) = try SyncWorld.openStore()

    await runtimes.launch(store, trustedClock: clock)
    let runtime = try #require(runtimes.runtime)
    await runtimes.launch(store, trustedClock: clock)

    #expect(runtimes.runtime === runtime)
    #expect(await runtime.currentPhase == .detached)
    #expect(runtimes.status == .off)
    try await SyncWorld.writeNovel("Ashfall", in: store)
    try await Task.sleep(for: .milliseconds(300))
    #expect(world.provider.listings == 0)
    #expect(try await world.provider.segments().isEmpty)
    await runtimes.shutDown()
  }

  @Test func shouldUploadACommittedLocalWriteToTheAttachedFolder() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes()
    let (store, _) = try await Self.attached(world, runtimes)
    let before = try await world.provider.segments().count

    try await SyncWorld.writeNovel("Ashfall", in: store)

    try await SyncWorld.until("the write shows as syncing") { runtimes.status == .syncing }
    try await SyncWorld.until("the write is uploaded") { try await SyncWorld.isUploaded(store) && runtimes.status == .upToDate }
    #expect(try await world.provider.segments().count > before)
    await runtimes.shutDown()
  }

  @Test func shouldSendWhatIsLeftInsideABackgroundTaskWhenTheAppGoesToTheBackground() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let tasks = BackgroundTasks()
    let runtimes = world.runtimes(background: tasks.runner)
    let (store, runtime) = try await Self.attached(world, runtimes)
    try await SyncWorld.writeNovel("Ashfall", in: store)
    try await SyncWorld.until("the write reaches the runtime") { runtime.status == .syncing }

    await runtimes.phaseChanged(.background)

    #expect(tasks.names == ["sync-final-upload"])
    #expect(try await SyncWorld.isUploaded(store))
    await runtimes.shutDown()
  }

  @Test func shouldShutTheRuntimeDownWhenAnotherVaultOpensOrTheVaultCloses() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes()
    let (first, _) = try await Self.attached(world, runtimes)
    let replaced = try #require(runtimes.runtime)
    let (second, clock) = try SyncWorld.openStore()

    await runtimes.launch(second, trustedClock: clock)

    let current = try #require(runtimes.runtime)
    #expect(current !== replaced)
    var updates = replaced.statusUpdates().makeAsyncIterator()
    _ = await updates.next()
    #expect(await updates.next() == nil)
    try await SyncWorld.until("the new vault joins the folder and is up to date") { runtimes.status == .upToDate }
    try await SyncWorld.writeNovel("Written in the closed vault", in: first)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await !SyncWorld.isUploaded(first))

    await runtimes.shutDown()

    #expect(runtimes.runtime == nil)
    #expect(runtimes.status == .off)
  }

  @Test func shouldCountAMacActivationAsAForegroundAtMostOncePerInterval() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes(activationInterval: .seconds(60))
    _ = try await Self.attached(world, runtimes)
    let start = ContinuousClock.now
    await runtimes.activated(at: start + .seconds(61))
    let afterFirst = world.provider.listings

    await runtimes.activated(at: start + .seconds(90))
    try await Task.sleep(for: .milliseconds(300))
    #expect(world.provider.listings == afterFirst)

    await runtimes.activated(at: start + .seconds(122))
    #expect(world.provider.listings > afterFirst)
    await runtimes.shutDown()
  }

  @Test func shouldAnswerASilentPushOnlyWhileAVaultSyncs() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes()
    #expect(await !runtimes.changeNotice())

    _ = try await Self.attached(world, runtimes)
    let before = world.provider.listings

    #expect(await runtimes.changeNotice())
    #expect(world.provider.listings > before)
    await runtimes.shutDown()
  }

  @Test func shouldNameAReplicaFromTheVaultsReplicaDirectoryAndLeaveAnUnknownOneOut() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes()
    let (store, _) = try await Self.attached(world, runtimes)
    let stranger = ReplicaID(UUID())

    let names = await SyncRuntimes.deviceNames(for: [store.replica, stranger], in: store)

    #expect(names == [store.replica: SyncWorld.device.name])
    #expect(await SyncRuntimes.deviceNames(for: [], in: store).isEmpty)
    await runtimes.shutDown()
  }

  @Test func shouldSyncNothingWithoutAFactory() async throws {
    let runtimes = SyncRuntimes(factory: nil)
    let (store, clock) = try SyncWorld.openStore()

    await runtimes.launch(store, trustedClock: clock)
    await runtimes.phaseChanged(.active)

    #expect(runtimes.runtime == nil)
    #expect(runtimes.status == .off)
    #expect(await !runtimes.changeNotice())
  }
}
