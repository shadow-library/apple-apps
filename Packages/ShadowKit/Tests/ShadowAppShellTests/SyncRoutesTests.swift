import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import SwiftUI
import Synchronization
import Testing

@testable import ShadowAppShell

/// What a vault's routes answer and were asked: the stores they name while `isOn`, and the class policies they were asked for.
nonisolated final class RouteSwitch: Sendable {
  private struct State {
    var isOn = true
    var policies: [StorageClassPolicy] = []
  }

  private let state = Mutex(State())
  let stores: [SyncedStore]

  init(_ stores: [SyncedStore]) {
    self.stores = stores
  }

  var policies: [StorageClassPolicy] { state.withLock { $0.policies } }

  func set(_ isOn: Bool) {
    state.withLock { $0.isOn = isOn }
  }

  func vault(primary: VaultStore) -> SyncedVault {
    SyncedVault(primary: primary, declaredRoutes: Set(stores.compactMap(\.route))) { policy in
      self.state.withLock { state in
        state.policies.append(policy)
        return state.isOn ? self.stores : []
      }
    }
  }
}

/// In-memory storage whose puts of routed segments wait while the gate is closed, as a slow upload would.
nonisolated final class GatedProvider: StorageProvider {
  private struct State {
    var isOpen = true
    var waiting: [CheckedContinuation<Void, Never>] = []
  }

  let inner = InMemoryStorageProvider()
  private let state = Mutex(State())

  var capabilities: StorageCapabilities { inner.capabilities }
  var waitingPuts: Int { state.withLock { $0.waiting.count } }

  func close() {
    state.withLock { $0.isOpen = false }
  }

  func open() {
    let waiting = state.withLock { state in
      state.isOpen = true
      defer { state.waiting = [] }
      return state.waiting
    }
    for continuation in waiting { continuation.resume() }
  }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage { try await inner.list(prefix: prefix, after: cursor) }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data { try await inner.get(key) }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    if key.hasPrefix("stores/"), key.rawValue.contains("/seg/") {
      await withCheckedContinuation { continuation in
        let isOpen = state.withLock { state in
          if !state.isOpen { state.waiting.append(continuation) }
          return state.isOpen
        }
        if isOpen { continuation.resume() }
      }
    }
    return try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) { try await inner.delete(keys) }

  func changeNotices() -> AsyncStream<Void> { inner.changeNotices() }
}

@MainActor
@Suite("Sync routes", TestTimeLimit.standard)
struct SyncRoutesTests {
  nonisolated private static let notes = SyncStoreRoute("notes")
  nonisolated private static let steps: EntityKind = {
    guard let kind = EntityKind("app_steps") else { preconditionFailure("fixture kind is valid") }
    return kind
  }()

  private static func route() throws -> SyncStoreRoute {
    try #require(notes)
  }

  private static func attach(_ world: SyncWorld, _ runtimes: SyncRuntimes, vault: SyncedVault, clock: TrustedClock) async throws {
    await runtimes.phaseChanged(.active)
    await runtimes.launch(vault, trustedClock: clock)
    let runtime = try #require(runtimes.runtime)
    #expect(try await runtime.attach(world.settings, choice: .create).canSync)
  }

  private static func routedSegments(_ world: SyncWorld, under route: SyncStoreRoute) async throws -> [ObjectKey] {
    try await world.provider.inner.listAll(prefix: route.prefix + VaultPath.replicasPrefix).map(\.key).filter { $0.rawValue.contains("/seg/") }
  }

  @Test func shouldShowTheWorstStatusAndThePrimarysOnATie() {
    let replica = ReplicaID(UUID())
    #expect(SyncRuntimes.worst([]) == nil)
    #expect(SyncRuntimes.worst([.off, .off]) == 0)
    #expect(SyncRuntimes.worst([.upToDate, .off]) == 0)
    #expect(SyncRuntimes.worst([.upToDate, .syncing]) == 1)
    #expect(SyncRuntimes.worst([.syncing, .attentionNeeded(.wrongClock(skew: .seconds(600), stopsUploads: false))]) == 1)
    #expect(SyncRuntimes.worst([.attentionNeeded(.keysMissing(replicas: [replica])), .attentionNeeded(.quotaFull)]) == 1)
    #expect(SyncRuntimes.worst([.attentionNeeded(.quotaFull), .attentionNeeded(.storageUnreachable)]) == 1)
    #expect(SyncRuntimes.worst([.attentionNeeded(.deviceLocked), .attentionNeeded(.deviceLocked)]) == 0)
  }

  @Test func shouldSayWhichDataAProblemConcernsOnlyWhenARouteNamesIt() throws {
    let scoped = try #require(SyncIndicator(.attentionNeeded(.quotaFull), scope: "activity data", app: .fixture))
    let whole = try #require(SyncIndicator(.attentionNeeded(.quotaFull), app: .fixture))
    let fine = try #require(SyncIndicator(.upToDate, app: .fixture))

    #expect(scoped.scope == "This concerns only your activity data.")
    #expect(whole.scope == nil)
    #expect(fine.scope == nil)
  }

  @Test func shouldStartARouteOnlyOnceThePrimaryAttachesAndSyncItUnderItsOwnPrefix() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes()
    let (primary, clock) = try SyncWorld.openStore()
    let routed = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: clock))
    let routes = RouteSwitch([SyncedStore(store: routed, route: try Self.route(), title: "notes")])

    await runtimes.launch(routes.vault(primary: primary), trustedClock: clock)

    #expect(runtimes.routed.isEmpty)
    #expect(routes.policies.isEmpty)
    #expect(try await world.provider.inner.listAll(prefix: "").isEmpty)

    let runtime = try #require(runtimes.runtime)
    await runtimes.phaseChanged(.active)
    #expect(try await runtime.attach(world.settings, choice: .create).canSync)
    try await SyncWorld.until("the route starts") { runtimes.routed[try Self.route()] != nil }
    let ref = try await ShellStore.writeNote("Routed", in: routed)
    try await SyncWorld.until("the routed write is uploaded") { try await SyncWorld.isUploaded(routed) && runtimes.status == .upToDate }

    #expect(routes.policies.allSatisfy { $0 == .unrestricted } && !routes.policies.isEmpty)
    #expect(try await !Self.routedSegments(world, under: try Self.route()).isEmpty)
    let primarySegments = try await world.provider.segments()
    #expect(try await ShellStore.title(of: ref, in: routed) == "Routed")
    #expect(try await ShellStore.title(of: ref, in: primary) == nil)
    #expect(primarySegments.allSatisfy { !$0.rawValue.hasPrefix("stores/") })
    await runtimes.shutDown()
    #expect(runtimes.routed.isEmpty)
  }

  @Test func shouldBringARoutesChangesToAnotherDeviceThroughTheSharedKeys() async throws {
    let keychain = InMemoryKeychain()
    let phone = try SyncWorld(keychain: keychain.device("phone"))
    defer { phone.remove() }
    let tablet = try SyncWorld(keychain: keychain.device("tablet"), storage: phone.folder)
    defer { tablet.remove() }
    let phoneRuntimes = phone.runtimes()
    let tabletRuntimes = tablet.runtimes()
    let (phoneStore, phoneClock) = try SyncWorld.openStore()
    let (tabletStore, tabletClock) = try SyncWorld.openStore()
    let phoneNotes = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: phoneClock))
    let tabletNotes = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: tabletClock))
    try await Self.attach(phone, phoneRuntimes, vault: RouteSwitch([SyncedStore(store: phoneNotes, route: try Self.route())]).vault(primary: phoneStore), clock: phoneClock)
    let ref = try await ShellStore.writeNote("From the phone", in: phoneNotes)
    try await SyncWorld.until("the phone uploads its routed note") { try await SyncWorld.isUploaded(phoneNotes) }
    keychain.deliver()
    let vault = try #require(await phoneRuntimes.runtime?.attachedLocation?.location.vault)

    await tabletRuntimes.phaseChanged(.active)
    await tabletRuntimes.launch(RouteSwitch([SyncedStore(store: tabletNotes, route: try Self.route())]).vault(primary: tabletStore), trustedClock: tabletClock)
    #expect(try await tabletRuntimes.runtime?.attach(tablet.settings, choice: .join(vault)).canSync == true)

    try await SyncWorld.until("the tablet reads the phone's routed note") { try await ShellStore.title(of: ref, in: tabletNotes) == "From the phone" }
    #expect(try await ShellStore.title(of: ref, in: tabletStore) == nil)
    await phoneRuntimes.shutDown()
    await tabletRuntimes.shutDown()
  }

  @Test func shouldStopARouteTheAppNoLongerNamesAndKeepItsRecordsOnTheDevice() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes()
    let (primary, clock) = try SyncWorld.openStore()
    let routed = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: clock))
    let routes = RouteSwitch([SyncedStore(store: routed, route: try Self.route())])
    try await Self.attach(world, runtimes, vault: routes.vault(primary: primary), clock: clock)
    try await SyncWorld.until("the route starts") { runtimes.routed[try Self.route()] != nil }
    let kept = try await ShellStore.writeNote("Kept here", in: routed)
    try await SyncWorld.until("the routed write is uploaded") { try await SyncWorld.isUploaded(routed) }
    let uploaded = try await Self.routedSegments(world, under: try Self.route()).count

    routes.set(false)
    await runtimes.reroute()

    #expect(runtimes.routed.isEmpty)
    #expect(try await ShellStore.title(of: kept, in: routed) == "Kept here")
    try await ShellStore.writeNote("Stays here", in: routed)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await !SyncWorld.isUploaded(routed))
    #expect(try await Self.routedSegments(world, under: try Self.route()).count == uploaded)
    try await SyncWorld.until("the stopped route's pending write leaves the status alone") { runtimes.status == .upToDate }

    routes.set(true)
    await runtimes.reroute()

    try await SyncWorld.until("the route syncs again") { try await SyncWorld.isUploaded(routed) }
    await runtimes.shutDown()
  }

  @Test func shouldStopEveryRouteWhenThePrimaryDetaches() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes()
    let (primary, clock) = try SyncWorld.openStore()
    let routed = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: clock))
    try await Self.attach(world, runtimes, vault: RouteSwitch([SyncedStore(store: routed, route: try Self.route())]).vault(primary: primary), clock: clock)
    try await SyncWorld.until("the route starts") { runtimes.routed[try Self.route()] != nil }

    try await runtimes.runtime?.detach()

    try await SyncWorld.until("the route stops with the primary") { runtimes.routed.isEmpty && runtimes.status == .off }
    await runtimes.shutDown()
  }

  @Test func shouldNeverPutAClassItsStorageRefusesAndSayWhichDataIsAffected() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let storage = InMemoryStorageProvider(classPolicy: .iCloud)
    let wiring = world.wiring
    let runtimes = SyncRuntimes(identity: .fixture) { synced, trustedClock in
      guard var environment = try? wiring.environment() else { return nil }
      environment.route = synced.route
      environment.routedStores = synced.routedBeside
      environment.provider = { _ in storage }
      return SyncRuntime(
        environment: environment, store: synced.store, device: wiring.device, trustedClock: trustedClock, configuration: synced.configuration,
        wallClock: SyncEngine.wallClock(preferring: trustedClock))
    }
    let (primary, clock) = try SyncWorld.openStore()
    let registry = SyncKernelSchema.registry(
      version: 1, adding: [EntitySchema(kind: Self.steps, shape: .record(fields: ["count": .register]), syncClass: .activity)])
    let activity = try VaultStore.open(.inMemory, registry: registry, migrations: SyncEngine.migrations, wallClock: SyncEngine.wallClock(preferring: clock))
    let routes = RouteSwitch([SyncedStore(store: activity, route: try Self.route(), title: "activity data")])
    let ref = EntityRef(kind: Self.steps, key: try #require(EntityKey("today")))
    _ = try await activity.write { transaction in try transaction.set(ref, ["count": .string("98765")]) }

    try await Self.attach(world, runtimes, vault: routes.vault(primary: primary), clock: clock)

    try await SyncWorld.until("the refusal shows for the activity data") {
      guard case .attentionNeeded = runtimes.status else { return false }
      return runtimes.attentionScope == "activity data"
    }
    #expect(routes.policies.contains(.iCloud))
    #expect(try await storage.listAll(prefix: try Self.route().prefix + VaultPath.replicasPrefix).allSatisfy { !$0.key.rawValue.contains("/seg/") })
    #expect(try await !SyncWorld.isUploaded(activity))
    await runtimes.shutDown()
  }

  @Test func shouldRefuseToMoveOrFollowAMoveOfARoutedVaultAndWriteNothing() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let target = world.directory.appending(path: "Target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let runtimes = world.runtimes()
    let (primary, clock) = try SyncWorld.openStore()
    let routed = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: clock))
    try await Self.attach(world, runtimes, vault: RouteSwitch([SyncedStore(store: routed, route: try Self.route())]).vault(primary: primary), clock: clock)
    try await SyncWorld.until("the route starts") { runtimes.routed[try Self.route()] != nil }
    try await SyncWorld.writeNote("Before the move", in: primary)
    try await SyncWorld.until("the primary is up to date") { try await SyncWorld.isUploaded(primary) && runtimes.status == .upToDate }
    let source = try await world.provider.inner.listAll(prefix: "")
    let runtime = try #require(runtimes.runtime)
    let settings = SyncProviderSettings.localFolder(SyncLocalFolderSettings(url: target))

    #expect(!runtimes.canMoveVault)
    let moving = await #expect(throws: SyncMoveError.self) { _ = try await runtime.moveVault(to: settings) }
    let following = await #expect(throws: SyncMoveError.self) { _ = try await runtime.followMove(to: settings) }
    #expect(moving?.code == SyncMoveError.routedStoresUnsupported.code)
    #expect(following?.code == SyncMoveError.routedStoresUnsupported.code)

    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path(percentEncoded: false)).isEmpty)
    #expect(try await world.provider.inner.listAll(prefix: "") == source)
    #expect(try world.wiring.locationStore().load() == .attached(try #require(await runtime.attachedLocation?.location)))
    await runtimes.shutDown()
  }

  @Test func shouldLetAVaultWithoutRoutesMove() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let runtimes = world.runtimes()
    let (primary, clock) = try SyncWorld.openStore()

    try await Self.attach(world, runtimes, vault: SyncedVault(primary: primary), clock: clock)

    #expect(runtimes.canMoveVault)
    await runtimes.shutDown()
  }

  @Test func shouldStopRoutesOnceThePrimaryHearsTheVaultMoved() async throws {
    let keychain = InMemoryKeychain()
    let mover = try SyncWorld(keychain: keychain.device("mac"))
    defer { mover.remove() }
    let routedWorld = try SyncWorld(keychain: keychain.device("phone"), storage: mover.folder)
    defer { routedWorld.remove() }
    let target = mover.directory.appending(path: "Moved", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let moverRuntimes = mover.runtimes()
    let routedRuntimes = routedWorld.runtimes()
    let (moverStore, moverClock) = try SyncWorld.openStore()
    let (phoneStore, phoneClock) = try SyncWorld.openStore()
    let phoneNotes = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: phoneClock))
    try await Self.attach(mover, moverRuntimes, vault: SyncedVault(primary: moverStore), clock: moverClock)
    let vault = try #require(await moverRuntimes.runtime?.attachedLocation?.location.vault)
    keychain.deliver()
    await routedRuntimes.phaseChanged(.active)
    await routedRuntimes.launch(RouteSwitch([SyncedStore(store: phoneNotes, route: try Self.route())]).vault(primary: phoneStore), trustedClock: phoneClock)
    let phone = try #require(routedRuntimes.runtime)
    #expect(try await phone.attach(routedWorld.settings, choice: .join(vault)).canSync)
    try await SyncWorld.until("the route starts") { routedRuntimes.routed[try Self.route()] != nil }

    guard case .moved = try await #require(moverRuntimes.runtime).moveVault(to: .localFolder(SyncLocalFolderSettings(url: target))) else {
      Issue.record("the vault without routes did not move")
      return
    }

    try await SyncWorld.until("the routed device hears of the move and stops its routes") {
      _ = await routedRuntimes.changeNotice()
      guard case .attentionNeeded(.vaultMoved) = routedRuntimes.status else { return false }
      return routedRuntimes.routed.isEmpty
    }
    await moverRuntimes.shutDown()
    await routedRuntimes.shutDown()
  }

  @Test func shouldLetARouteReadAsSoonAsThePrimaryReceivesTheVaultsKey() async throws {
    let keychain = InMemoryKeychain()
    let mac = try SyncWorld(keychain: keychain.device("mac"))
    defer { mac.remove() }
    let phone = try SyncWorld(keychain: keychain.device("phone"), storage: mac.folder)
    defer { phone.remove() }
    let macRuntimes = mac.runtimes()
    let phoneRuntimes = phone.runtimes()
    let (macStore, macClock) = try SyncWorld.openStore()
    let (phoneStore, phoneClock) = try SyncWorld.openStore()
    let macNotes = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: macClock))
    let phoneNotes = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: phoneClock))
    try await Self.attach(mac, macRuntimes, vault: RouteSwitch([SyncedStore(store: macNotes, route: try Self.route())]).vault(primary: macStore), clock: macClock)
    let ref = try await ShellStore.writeNote("From the mac", in: macNotes)
    try await SyncWorld.until("the mac uploads its routed note") { try await SyncWorld.isUploaded(macNotes) }
    let vault = try #require(await macRuntimes.runtime?.attachedLocation?.location.vault)
    await phoneRuntimes.phaseChanged(.active)
    await phoneRuntimes.launch(RouteSwitch([SyncedStore(store: phoneNotes, route: try Self.route())]).vault(primary: phoneStore), trustedClock: phoneClock)
    let primary = try #require(phoneRuntimes.runtime)
    _ = try await primary.attach(phone.settings, choice: .join(vault))
    try await SyncWorld.until("the phone waits for the key with its route started") {
      routedStatus(phoneRuntimes) == .attentionNeeded(.awaitingKey) && phoneRuntimes.status == .attentionNeeded(.awaitingKey)
    }

    keychain.deliver()
    await primary.foreground()

    try await SyncWorld.until("the route reads the mac's note well before its own key check") { try await ShellStore.title(of: ref, in: phoneNotes) == "From the mac" }
    await macRuntimes.shutDown()
    await phoneRuntimes.shutDown()
  }

  private func routedStatus(_ runtimes: SyncRuntimes) -> SyncStatus? {
    runtimes.routed.values.first?.status
  }

  private static func gatedRuntimes(_ world: SyncWorld, _ storage: GatedProvider) -> SyncRuntimes {
    let wiring = world.wiring
    return SyncRuntimes(identity: .fixture) { synced, trustedClock in
      guard var environment = try? wiring.environment() else { return nil }
      environment.route = synced.route
      environment.routedStores = synced.routedBeside
      environment.provider = { _ in storage }
      return SyncRuntime(
        environment: environment, store: synced.store, device: wiring.device, trustedClock: trustedClock, configuration: synced.configuration,
        wallClock: SyncEngine.wallClock(preferring: trustedClock))
    }
  }

  /// A routed store of five notes, one segment each, whose first routed put is held at the gate.
  private static func heldUpload(_ world: SyncWorld, _ storage: GatedProvider) async throws -> (SyncRuntimes, RouteSwitch, VaultStore) {
    let runtimes = gatedRuntimes(world, storage)
    let (primary, clock) = try SyncWorld.openStore()
    let routed = try ShellStore.open(wallClock: SyncEngine.wallClock(preferring: clock))
    for index in 1...5 { try await ShellStore.writeNote("Note \(index)", in: routed) }
    let routes = RouteSwitch([SyncedStore(store: routed, route: try route(), configuration: SyncConfiguration(maximumSegmentLines: 1))])
    storage.close()
    try await attach(world, runtimes, vault: routes.vault(primary: primary), clock: clock)
    try await SyncWorld.until("the route's first segment waits at the gate") { storage.waitingPuts == 1 }
    return (runtimes, routes, routed)
  }

  private static func routedRanges(in storage: GatedProvider) async throws -> [ClosedRange<Int64>] {
    try await storage.inner.listAll(prefix: try route().prefix + VaultPath.replicasPrefix).compactMap { object in
      guard let name = object.key.rawValue.split(separator: "/seg/").last else { return nil }
      let parts = name.split(separator: "-")
      guard object.key.rawValue.contains("/seg/"), parts.count >= 2, let first = Int64(parts[0]), let last = Int64(parts[1]) else { return nil }
      return first...last
    }
  }

  @Test func shouldStopSendingAtOnceWhenARouteIsTurnedOffMidUpload() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let storage = GatedProvider()
    let (runtimes, routes, routed) = try await Self.heldUpload(world, storage)
    let pending = try await routed.pendingChanges(limit: .max).count

    routes.set(false)
    let off = Task { await runtimes.reroute() }
    try await SyncWorld.until("the route is off") { runtimes.routed.isEmpty }
    storage.open()
    await off.value

    let landed = try await Self.routedRanges(in: storage)
    #expect(landed.count <= 1)
    #expect(try await routed.pendingChanges(limit: .max).count >= pending - 1)
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await Self.routedRanges(in: storage).count == landed.count)
    await runtimes.shutDown()
  }

  @Test func shouldResumeOnTheSameReplicaWhenARouteIsTurnedOffAndOnMidUpload() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let storage = GatedProvider()
    let (runtimes, routes, routed) = try await Self.heldUpload(world, storage)
    let replica = routed.replica

    routes.set(false)
    let off = Task { await runtimes.reroute() }
    try await SyncWorld.until("the route is off") { runtimes.routed.isEmpty }
    routes.set(true)
    let on = Task { await runtimes.reroute() }
    storage.open()
    await off.value
    await on.value

    try await SyncWorld.until("the route uploads everything") { try await SyncWorld.isUploaded(routed) }
    #expect(routed.replica == replica)
    let ranges = try await Self.routedRanges(in: storage).sorted { $0.lowerBound < $1.lowerBound }
    #expect(ranges.first?.lowerBound == 1)
    #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound + 1 == $1.lowerBound })
    await runtimes.shutDown()
  }
}
