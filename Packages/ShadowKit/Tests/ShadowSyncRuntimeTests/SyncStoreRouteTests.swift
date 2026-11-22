import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncRuntime

@Suite("SyncStoreRoute", TestTimeLimit.standard)
struct SyncStoreRouteTests {
  private static let activity = SyncStoreRoute("activity")

  private static func route() throws -> SyncStoreRoute {
    try #require(activity)
  }

  private static func key(_ raw: String) throws -> ObjectKey {
    try #require(ObjectKey(raw))
  }

  private static func routeStartup(_ keychain: InMemoryKeychain.Device, provider: any StorageProvider, directory: TemporaryDirectory) throws -> SyncStartup {
    SyncStartup(
      SyncStartupEnvironment(
        locationStore: try directory.locationStore(), stores: RuntimeFixture.stores(keychain), automatic: RuntimeFixture.iCloud, provider: { _ in provider },
        account: { _ in .available(SyncAccountBinding(kind: .iCloud, account: "user-one")) }, hasUnlockedSinceBoot: { true }, route: try route()))
  }

  @Test func shouldAcceptOnlyShortLowerCaseNames() {
    #expect(SyncStoreRoute("health-2") != nil)
    #expect(SyncStoreRoute("") == nil)
    #expect(SyncStoreRoute("Activity") == nil)
    #expect(SyncStoreRoute("a/b") == nil)
    #expect(SyncStoreRoute(String(repeating: "a", count: SyncStoreRoute.maximumNameLength)) != nil)
    #expect(SyncStoreRoute(String(repeating: "a", count: SyncStoreRoute.maximumNameLength + 1)) == nil)
  }

  @Test func shouldDeriveTheSameVaultOnEveryDeviceAndADifferentOnePerRouteAndPrimary() throws {
    let route = try Self.route()
    let health = try #require(SyncStoreRoute("health"))
    let primary = RuntimeFixture.vault("vault-a")

    #expect(route.vault(of: primary) == route.vault(of: RuntimeFixture.vault("vault-a")))
    #expect(route.vault(of: primary) != health.vault(of: primary))
    #expect(route.vault(of: primary) != route.vault(of: RuntimeFixture.vault("vault-b")))
    #expect(route.vault(of: primary) != primary)
    #expect(route.prefix == "stores/activity/")
  }

  @Test func shouldReadAndWriteUnderTheRoutePrefixAndListOnlyWhatIsThere() async throws {
    let base = InMemoryStorageProvider()
    let routed = RoutedStorageProvider(base: base, route: try Self.route())
    _ = try await base.put(try Self.key("replicas/r1/manifest"), data: Data("primary".utf8), condition: .ifAbsent)

    _ = try await routed.put(try Self.key("replicas/r2/manifest"), data: Data("route".utf8), condition: .ifAbsent)

    #expect(try await base.get(try Self.key("stores/activity/replicas/r2/manifest")) == Data("route".utf8))
    #expect(try await routed.get(try Self.key("replicas/r2/manifest")) == Data("route".utf8))
    #expect(try await routed.listAll(prefix: "replicas/").map(\.key.rawValue) == ["replicas/r2/manifest"])
    #expect(try await base.listAll(prefix: VaultPath.replicasPrefix).map(\.key.rawValue) == ["replicas/r1/manifest"])
    await #expect(throws: StorageError.alreadyExists(try Self.key("replicas/r2/manifest"))) {
      _ = try await routed.put(try Self.key("replicas/r2/manifest"), data: Data(), condition: .ifAbsent)
    }

    try await routed.delete([try Self.key("replicas/r2/manifest")])

    await #expect(throws: StorageError.notFound(try Self.key("replicas/r2/manifest"))) { _ = try await routed.get(try Self.key("replicas/r2/manifest")) }
    #expect(try await base.get(try Self.key("replicas/r1/manifest")) == Data("primary".utf8))
  }

  @Test func shouldRefuseAKeyTooLongForTheRoutePrefix() async throws {
    let routed = RoutedStorageProvider(base: InMemoryStorageProvider(), route: try Self.route())
    let longest = try Self.key(String(repeating: "a", count: ObjectKey.maxUTF8Length))

    await #expect(throws: StorageError.self) { _ = try await routed.put(longest, data: Data(), condition: .overwrite) }
  }

  @Test func shouldNeverCreateAVaultOnFirstUseAndRefuseToAttachDetachOrMove() async throws {
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain().device("phone")
    let directory = try TemporaryDirectory()
    let startup = try Self.routeStartup(keychain, provider: provider, directory: directory)

    #expect(try await startup.evaluate().phase == .detached)
    #expect(provider.callCounts.put == 0)
    #expect(try directory.locationStore().load() == .firstUse)
    await #expect(throws: SyncStartupError.notAttached) { _ = try await startup.attach(RuntimeFixture.iCloud, choice: .create) }
    await #expect(throws: SyncStartupError.notAttached) { try await startup.detach() }
    await #expect(throws: SyncStartupError.notAttached) { _ = try await startup.moveContext(to: nil) }
    #expect(try directory.locationStore().load() == .firstUse)
  }

  @Test func shouldHandOutTheDerivedVaultUnderThePrefixWithThePrimarysRing() async throws {
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain().device("phone")
    let primary = try RuntimeDevice(keychain, provider: provider)
    let primaryResult = try await primary.startup.evaluate()
    let vault = try #require(primaryResult.attachment?.vault)
    let route = try Self.route()

    let result = try await Self.routeStartup(keychain, provider: provider, directory: primary.directory).evaluate()

    #expect(result.phase == .vault(.ready(vault: vault)))
    let attachment = try #require(result.attachment)
    #expect(attachment.vault == route.vault(of: vault))
    #expect(attachment.ring.vault == vault)
    #expect(attachment.ring.keyIDs == primaryResult.attachment?.ring.keyIDs)
    #expect((attachment.provider as? RoutedStorageProvider)?.route == route)
    #expect(try RuntimeFixture.ringKeys(keychain, vault: attachment.vault).isEmpty)
  }

  @Test func shouldSyncARouteBetweenTwoDevicesWithoutTouchingThePrimarysFiles() async throws {
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let phone = try RuntimeDevice(keychain.device("phone"), provider: provider)
    let vault = try #require(try await phone.startup.evaluate().attachment?.vault)
    let tablet = try RuntimeDevice(keychain.device("tablet"), provider: provider)
    keychain.deliver()
    #expect(try await tablet.startup.evaluate().attachment?.vault == vault)
    let phoneRoute = try #require(try await Self.routeStartup(keychain.device("phone"), provider: provider, directory: phone.directory).evaluate().attachment)
    let tabletRoute = try #require(try await Self.routeStartup(keychain.device("tablet"), provider: provider, directory: tablet.directory).evaluate().attachment)
    let written = try RuntimeFixture.openStore()
    let read = try RuntimeFixture.openStore()
    let ref = EntityRef(kind: RuntimeFixture.note, key: try #require(EntityKey("n1")))
    _ = try await written.write { transaction in try transaction.set(ref, ["title": .string("Routed")]) }
    let sender = phoneRoute.engine(store: written, device: RuntimeFixture.phone, trustedClock: TrustedClock())
    let receiver = tabletRoute.engine(store: read, device: RuntimeFixture.tablet, trustedClock: TrustedClock())
    _ = try await sender.start()
    _ = try await receiver.start()

    _ = try await sender.upload()
    _ = try await receiver.download()

    guard case .record(let record)? = try await read.read({ try $0.state(of: ref) }), case .string(let title)? = record[field: "title"]?.value else {
      throw RuntimeFixtureFailure("the routed note did not arrive")
    }
    #expect(title == "Routed")
    let everything = try await provider.listAll(prefix: "").map(\.key.rawValue)
    #expect(everything.contains { $0.hasPrefix("stores/activity/replicas/") })
    #expect(!everything.contains { $0.hasPrefix("replicas/") })
  }
}
