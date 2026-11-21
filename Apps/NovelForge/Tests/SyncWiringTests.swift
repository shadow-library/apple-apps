import Foundation
import ShadowSync
import ShadowSyncCloudKit
import ShadowSyncRuntime
import ShadowSyncS3
import ShadowTestSupport
import SwiftUI
import Synchronization
import Testing

@testable import NovelForge

nonisolated final class CloudKitClients: Sendable {
  let zone = FakeCloudKitZone(configuration: CloudKitClients.configuration)
  private let made = Mutex(0)

  static let configuration: CloudKitConfiguration = {
    guard let configuration = try? CloudKitConfiguration(containerIdentifier: "iCloud.com.shadow.apps.novelforge") else { preconditionFailure("fixture container is valid") }
    return configuration
  }()

  var count: Int { made.withLock(\.self) }

  func access() -> CloudKitAccess {
    CloudKitAccess(configuration: Self.configuration, stateStore: InMemoryCloudKitStateStore()) { _ throws(CloudKitConfigurationError) in
      self.made.withLock { $0 += 1 }
      return self.zone
    }
  }
}

@MainActor
@Suite("Sync wiring", TestTimeLimit.standard)
struct SyncWiringTests {
  @Test func shouldReadNoCapabilityFromABuildSignedWithoutATeam() {
    let teamless = SyncCapabilities(infoDictionary: ["CFBundleIdentifier": "com.shadow.apps.novelforge"])

    #expect(teamless == SyncCapabilities())
    #expect(teamless.cloudKit == nil)
    #expect(!teamless.receivesPushes)
    #expect(teamless.sharedKeychainGroup == nil)
  }

  @Test func shouldOfferICloudOnlyWithBothTheContainerAndPushes() {
    let markers: [String: Any] = [
      "CloudKitContainer": "iCloud.com.shadow.apps.novelforge", "PushNotifications": true, "SharedKeychainGroup": "ABCDE12345.com.shadow.apps.shared",
    ]
    let signed = SyncCapabilities(infoDictionary: [SyncCapabilities.infoPlistKey: markers])
    let withoutPushes = SyncCapabilities(infoDictionary: [SyncCapabilities.infoPlistKey: ["CloudKitContainer": "iCloud.com.shadow.apps.novelforge"]])

    #expect(signed.cloudKit == CloudKitClients.configuration)
    #expect(signed.receivesPushes)
    #expect(signed.sharedKeychainGroup == "ABCDE12345.com.shadow.apps.shared")
    #expect(withoutPushes.cloudKit == nil)
  }

  @Test(arguments: ["$(AppIdentifierPrefix)com.shadow.apps.shared", ".com.shadow.apps.shared", "abcde12345.com.shadow.apps.shared", "ABCDE12345.", "com.shadow.apps.shared"])
  func shouldKeepKeysInTheAppsOwnGroupWhenTheSharedGroupWasNotExpanded(group: String) {
    #expect(SyncCapabilities.expandedGroup(group) == nil)
    #expect(SyncCapabilities(infoDictionary: [SyncCapabilities.infoPlistKey: ["SharedKeychainGroup": group]]).sharedKeychainGroup == nil)
  }

  @Test func shouldNeverTouchCloudKitInABuildWithoutTheICloudCapability() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let live = try SyncWiring.live(capabilities: SyncCapabilities(infoDictionary: [:]))
    let environment = try world.wiring.environment()

    #expect(live.cloudKit == nil)
    #expect(world.wiring.cloudKit == nil)
    #expect(environment.automatic == nil)
    #expect(await world.wiring.account(for: .iCloud(SyncICloudSettings(CloudKitClients.configuration))) == .noAccount)
    #expect(throws: StorageError.self) { try world.wiring.provider(for: .iCloud(SyncICloudSettings(CloudKitClients.configuration))) }

    let runtimes = world.runtimes()
    let (store, clock) = try SyncWorld.openStore()
    await runtimes.launch(store, trustedClock: clock)
    #expect(await runtimes.runtime?.currentPhase == .detached)
    await runtimes.shutDown()
  }

  @Test func shouldAttachICloudOnItsOwnOnFirstUseWithOneClientBoundToTheUserRecord() async throws {
    let clients = CloudKitClients()
    clients.zone.signIn("user-one", notify: false)
    let world = try SyncWorld(cloudKit: clients.access())
    defer { world.remove() }
    let runtimes = world.runtimes()
    let (store, clock) = try SyncWorld.openStore()

    await runtimes.phaseChanged(.active)
    await runtimes.launch(store, trustedClock: clock)

    try await SyncWorld.until("iCloud is attached and up to date") { runtimes.status == .upToDate }
    let location = try SyncLocationStore(url: world.wiring.paths.location, outside: [world.wiring.paths.vaultDirectory]).load()
    guard case .attached(let attached) = location else {
      Issue.record("expected an attached location, found \(location)")
      return
    }
    #expect(attached.settings == .iCloud(SyncICloudSettings(CloudKitClients.configuration)))
    #expect(attached.account == SyncAccountBinding(kind: .iCloud, account: "user-one"))
    #expect(clients.count == 1)
    await runtimes.shutDown()
  }

  @Test func shouldReportNoAccountWhileSignedOutAndRefuseAnotherContainer() async throws {
    let clients = CloudKitClients()
    clients.zone.signOut()
    let access = clients.access()
    guard let other = try? CloudKitConfiguration(containerIdentifier: "iCloud.com.shadow.apps.other") else { return }

    #expect(await access.account() == .noAccount)
    #expect(throws: StorageError.self) { try access.provider(for: SyncICloudSettings(other)) }
    _ = try access.provider(for: access.settings)
    #expect(clients.count == 1)
  }

  @Test func shouldNeedStoredCredentialsForS3AndNoAccountForALocalFolder() async throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let s3 = SyncS3Settings(try S3Configuration(endpoint: try #require(URL(string: "https://s3.example.com")), region: "eu-west-1", bucket: "novels"))

    #expect(throws: StorageError.unauthenticated) { try world.wiring.provider(for: .s3(s3)) }
    #expect(await world.wiring.account(for: .s3(s3)) == .available(nil))
    #expect(await world.wiring.account(for: .localFolder(SyncLocalFolderSettings(url: world.folder))) == .available(nil))
  }
}
