import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowSync
import ShadowSyncOneDrive
import ShadowSyncRuntime
import ShadowTestSupport
import Testing

@Suite("SyncStartup", TestTimeLimit.standard)
struct SyncStartupTests {
  private static let userOne = SyncAccountBinding(kind: .iCloud, account: "user-one")
  private static let userTwo = SyncAccountBinding(kind: .iCloud, account: "user-two")

  private static func oneDrive() throws -> SyncProviderSettings {
    let configuration = try OneDriveConfiguration(
      clientID: "client-one", redirectURI: try #require(URL(string: "com.shadow.apps.test:/oauth")), vaultFolder: try #require(VaultFolderName("Vault")))
    return .oneDrive(SyncOneDriveSettings(configuration))
  }

  private static func vault(of result: SyncStartupResult) throws -> VaultID {
    try #require(result.location?.vault)
  }

  @Test("should stay detached without a location or an automatic provider and touch nothing")
  func detached() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider, automatic: nil)

    let result = try await device.startup.evaluate()

    #expect(result.phase == .detached)
    #expect(result.attachment == nil)
    #expect(provider.isUntouched)
  }

  @Test("should report no storage account and create nothing while iCloud has no account")
  func noAccount() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider, account: AccountSwitch(.noAccount))

    #expect(try await device.startup.evaluate().phase == .vault(.noStorageAccount))
    #expect(provider.isUntouched)
    #expect(try device.directory.locationStore().load() == .firstUse)
  }

  @Test("should create a vault on an empty iCloud location and be ready with its key")
  func createsAutomatically() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)

    let result = try await device.startup.evaluate()

    let vault = try Self.vault(of: result)
    #expect(result.phase == .vault(.ready(vault: vault)))
    #expect(result.attachment?.vault == vault)
    #expect(try await RuntimeFixture.hint(in: provider) == vault)
    #expect(try RuntimeFixture.ringKeys(device.keychain, vault: vault).count == 1)
    #expect(try device.directory.locationStore().load() == .attached(SyncLocation(settings: RuntimeFixture.iCloud, vault: vault, account: Self.userOne)))
    #expect(try await device.startup.evaluate().phase == .vault(.ready(vault: vault)))
    #expect(provider.callCounts.put == 1)
  }

  @Test("should wait for the key on a second device and become ready once the keychain delivers it")
  func secondDeviceWaitsForKey() async throws {
    let keychain = InMemoryKeychain()
    let provider = InMemoryStorageProvider()
    let phone = try RuntimeDevice(keychain.device("phone"), provider: provider)
    let vault = try Self.vault(of: try await phone.startup.evaluate())
    let tablet = try RuntimeDevice(keychain.device("tablet"), provider: provider)

    let waiting = try await tablet.startup.evaluate()
    #expect(waiting.phase == .vault(.awaitingKey(vault: vault)))
    #expect(try await tablet.startup.evaluate().phase == .vault(.awaitingKey(vault: vault)))
    #expect(try RuntimeFixture.ringKeys(tablet.keychain, vault: vault).isEmpty)

    keychain.deliver()

    #expect(try await tablet.startup.evaluate().phase == .vault(.ready(vault: vault)))
    #expect(try RuntimeFixture.ringKeys(tablet.keychain, vault: vault).count == 1)
    #expect(try await RuntimeFixture.hint(in: provider) == vault)
  }

  @Test("should converge on one vault when two devices create at the same moment")
  func simultaneousCreation() async throws {
    let keychain = InMemoryKeychain()
    let provider = HintRaceProvider(writers: 2)
    let phone = try RuntimeDevice(keychain.device("phone"), provider: provider)
    let tablet = try RuntimeDevice(keychain.device("tablet"), provider: provider)

    async let phoneResult = phone.startup.evaluate()
    async let tabletResult = tablet.startup.evaluate()
    let results = try await [phoneResult, tabletResult]

    let vault = try #require(try await RuntimeFixture.hint(in: provider))
    #expect(try results.map(Self.vault(of:)) == [vault, vault])
    #expect(results.map(\.phase).filter { $0 == .vault(.ready(vault: vault)) }.count == 1)
    #expect(results.map(\.phase).filter { $0 == .vault(.awaitingKey(vault: vault)) }.count == 1)

    keychain.deliver()

    #expect(try await phone.startup.evaluate().phase == .vault(.ready(vault: vault)))
    #expect(try await tablet.startup.evaluate().phase == .vault(.ready(vault: vault)))
    #expect(try RuntimeFixture.ringKeys(phone.keychain, vault: vault).count == 1)
    #expect(try RuntimeFixture.ringKeys(tablet.keychain, vault: vault).count == 1)
    #expect(try await provider.inner.listAll(prefix: "").map(\.key) == [VaultPath.hint])
  }

  @Test("should run concurrent evaluations on one device one at a time and create one vault")
  func serialisesEvaluations() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)

    async let first = device.startup.evaluate()
    async let second = device.startup.evaluate()
    let results = try await [first, second]

    let vault = try Self.vault(of: results[0])
    #expect(results.map(\.phase) == [.vault(.ready(vault: vault)), .vault(.ready(vault: vault))])
    #expect(try device.keychain.store(service: RuntimeFixture.ringService, scope: .synced).allKeys().count == 1)
    #expect(provider.callCounts.put == 1)
  }

  @Test("should detach on an account switch without uploading and keep the saved location")
  func accountSwitch() async throws {
    let provider = InMemoryStorageProvider()
    let account = AccountSwitch(.available(Self.userOne))
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider, account: account)
    let attached = try await device.startup.evaluate()
    let before = provider.callCounts

    account.set(.available(Self.userTwo))
    let switched = try await device.startup.evaluate()

    #expect(switched.phase == .accountChanged)
    #expect(switched.attachment == nil)
    #expect(provider.callCounts == before)
    #expect(try device.directory.locationStore().load() == .attached(try #require(attached.location)))

    account.set(.available(Self.userOne))
    #expect(try await device.startup.evaluate().phase == attached.phase)
  }

  @Test("should pause while the attached account is signed out or cannot say who it is")
  func accountUnavailable() async throws {
    let provider = InMemoryStorageProvider()
    let account = AccountSwitch(.available(Self.userOne))
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider, account: account)
    _ = try await device.startup.evaluate()

    for status in [SyncAccountStatus.noAccount, .temporarilyUnavailable, .available(nil)] {
      account.set(status)
      let result = try await device.startup.evaluate()
      #expect(result.phase == .accountUnavailable)
      #expect(result.attachment == nil)
    }
  }

  @Test("should refuse a location whose hint now names another vault")
  func wrongVaultHint() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)
    let vault = try Self.vault(of: try await device.startup.evaluate())
    let other = RuntimeFixture.vault("vault-other")
    _ = try await provider.put(VaultPath.hint, data: VaultHint(vault: other).encoded(), condition: .overwrite)

    let result = try await device.startup.evaluate()

    #expect(result.phase == .vaultMismatch(expected: vault, found: other))
    #expect(result.attachment == nil)
  }

  @Test("should report removed storage and never create the vault again on its own")
  func storageRemoved() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)
    _ = try await device.startup.evaluate()
    try await provider.delete([VaultPath.hint])

    #expect(try await device.startup.evaluate().phase == .storageRemoved)
    #expect(try await RuntimeFixture.hint(in: provider) == nil)
    #expect(provider.callCounts.put == 1)
  }

  @Test("should ask for an update when the hint was written by a newer app")
  func newerHint() async throws {
    let provider = InMemoryStorageProvider()
    _ = try await provider.put(VaultPath.hint, data: Data(#"{"format":9,"vault":"vault-other"}"#.utf8), condition: .ifAbsent)
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)

    #expect(try await device.startup.evaluate().phase == .appUpdateRequired)
    #expect(try device.directory.locationStore().load() == .firstUse)
  }

  @Test("should report a locked device before the first unlock without touching storage or the keychain")
  func notUnlockedSinceBoot() async throws {
    let provider = InMemoryStorageProvider()
    let unlocked = UnlockAnswers([false])
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider, unlocked: unlocked)

    #expect(try await device.startup.evaluate().phase == .deviceLocked)
    #expect(provider.isUntouched)

    unlocked.set([true])
    #expect(try await device.startup.evaluate().phase.canSync)
  }

  @Test("should report a refused location file as locked only while the device has not been unlocked since it started")
  func refusedLocationFile() async throws {
    let provider = InMemoryStorageProvider()
    let unlocked = UnlockAnswers([true])
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider, unlocked: unlocked)
    _ = try await device.startup.evaluate()
    let path = try device.directory.locationStore().url.path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }

    let error = try await #require(throws: SyncStartupError.self) { try await device.startup.evaluate() }
    guard case .location(.permissionDenied) = error else { throw RuntimeFixtureFailure("expected a location error, got \(error)") }

    unlocked.set([true, false])
    #expect(try await device.startup.evaluate().phase == .deviceLocked)
  }

  @Test("should report a locked device when the keychain refuses before the first unlock")
  func lockedKeychain() async throws {
    let keychain = InMemoryKeychain()
    let provider = InMemoryStorageProvider()
    let phone = try RuntimeDevice(keychain.device("phone"), provider: provider)
    let vault = try Self.vault(of: try await phone.startup.evaluate())
    let unlocked = RuntimeFixture.stores(keychain.device("tablet"))
    let locked = SyncSecureStores(ring: LockedSecureStore(), credentials: unlocked.credentials, marker: unlocked.marker, tokens: unlocked.tokens)
    let tablet = try RuntimeDevice(keychain.device("tablet"), provider: provider, stores: locked)

    #expect(try await tablet.startup.evaluate().phase == .deviceLocked)
    #expect(try await RuntimeFixture.hint(in: provider) == vault)
    #expect(provider.callCounts.put == 1)
  }

  @Test("should attach nothing on its own after a corrupt location file until sync is turned on")
  func corruptLocationStaysOff() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)
    let vault = try Self.vault(of: try await device.startup.evaluate())
    try Data("{".utf8).write(to: try device.directory.locationStore().url)
    let before = provider.callCounts

    #expect(try await device.startup.evaluate().phase == .settingsUnreadable)
    #expect(provider.callCounts == before)

    #expect(try await device.startup.attach(RuntimeFixture.iCloud, choice: .join(vault)).phase == .vault(.ready(vault: vault)))
  }

  @Test("should ask for an update and touch nothing when a newer app wrote the location file")
  func newerLocationFile() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)
    _ = try await device.startup.evaluate()
    try Data(#"{"format":2,"kind":"iCloud"}"#.utf8).write(to: try device.directory.locationStore().url)
    let before = provider.callCounts

    #expect(try await device.startup.evaluate().phase == .appUpdateRequired)
    #expect(provider.callCounts == before)
  }

  @Test("should report the keys downloads of the attached vault found missing until they arrive")
  func partiallyReadable() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)
    let vault = try Self.vault(of: try await device.startup.evaluate())
    let missing = [RuntimeFixture.keyID(7): Set([ReplicaID(UUID.v7())])]

    await device.startup.noteMissingKeys(missing, vault: RuntimeFixture.vault("vault-other"))
    #expect(try await device.startup.evaluate().phase == .vault(.ready(vault: vault)))

    await device.startup.noteMissingKeys(missing, vault: vault)

    #expect(try await device.startup.evaluate().phase == .vault(.partiallyReadable(vault: vault, missing: missing)))
    await device.startup.noteMissingKeys([:], vault: vault)
    #expect(try await device.startup.evaluate().phase == .vault(.ready(vault: vault)))
  }

  @Test("should throw a transient storage failure and recover on the next evaluation")
  func transientFailure() async throws {
    let provider = ScriptedProvider(script: ScriptedProvider.Script(failingGets: 1))
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)

    await #expect(throws: SyncStartupError.setup(.storage(.unavailable("scripted failure")))) { try await device.startup.evaluate() }
    #expect(try device.directory.locationStore().load() == .firstUse)
    #expect(try await device.startup.evaluate().phase.canSync)
  }

  @Test("should report an unauthenticated provider as an unavailable account")
  func unauthenticated() async throws {
    let provider = ScriptedProvider(script: ScriptedProvider.Script(failingPuts: 1, putFailure: .unauthenticated))
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider)

    #expect(try await device.startup.evaluate().phase == .accountUnavailable)
  }

  @Test("should attach an explicit provider only through a create or join choice")
  func explicitChoice() async throws {
    let keychain = InMemoryKeychain()
    let provider = InMemoryStorageProvider()
    let settings = RuntimeFixture.localFolder("shared")
    let phone = try RuntimeDevice(keychain.device("phone"), provider: provider, automatic: nil, account: AccountSwitch(.available(nil)))
    let tablet = try RuntimeDevice(keychain.device("tablet"), provider: provider, automatic: nil, account: AccountSwitch(.available(nil)))
    #expect(try await phone.startup.discover(settings) == .empty)

    let created = try await phone.startup.attach(settings, choice: .create)
    let vault = try Self.vault(of: created)
    #expect(created.phase == .vault(.ready(vault: vault)))
    #expect(try await tablet.startup.evaluate().phase == .detached)
    #expect(try await tablet.startup.discover(settings) == .found(vault))

    let other = RuntimeFixture.vault("vault-other")
    await #expect(throws: SyncStartupError.setup(.vaultMismatch(expected: other, found: vault))) { try await tablet.startup.attach(settings, choice: .join(other)) }
    let joined = try await tablet.startup.attach(settings, choice: .join(vault))

    #expect(joined.phase == .vault(.awaitingKey(vault: vault)))
    #expect(joined.location == SyncLocation(settings: settings, vault: vault, account: nil))
    await #expect(throws: SyncStartupError.alreadyAttached) { try await tablet.startup.attach(settings, choice: .create) }
    #expect(try RuntimeFixture.ringKeys(tablet.keychain, vault: vault).isEmpty)
  }

  @Test("should forget the location on detach and leave the vault where it is")
  func detach() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider, automatic: nil)
    let vault = try Self.vault(of: try await device.startup.attach(RuntimeFixture.localFolder("a"), choice: .create))

    try await device.startup.detach()

    #expect(try await device.startup.evaluate().phase == .detached)
    #expect(try await RuntimeFixture.hint(in: provider) == vault)
    #expect(try RuntimeFixture.ringKeys(device.keychain, vault: vault).count == 1)
  }

  @Test("should re-mint the replica of a restored database whose device marker is missing")
  func restoredDatabaseRemints() async throws {
    let keychain = InMemoryKeychain()
    let provider = InMemoryStorageProvider()
    let store = try RuntimeFixture.openStore()
    let clock = TrustedClock(wallClock: { RuntimeFixture.start })
    let phone = try RuntimeDevice(keychain.device("phone"), provider: provider)
    let phoneAttachment = try #require(try await phone.startup.evaluate().attachment)
    guard case .claimed = try await phoneAttachment.engine(store: store, device: RuntimeFixture.phone, trustedClock: clock).start() else {
      throw RuntimeFixtureFailure("the first start claims a replica")
    }
    let original = store.replica
    keychain.deliver()
    let restored = try RuntimeDevice(keychain.device("tablet"), provider: provider)
    let restoredAttachment = try #require(try await restored.startup.evaluate().attachment)

    let bootstrap = try await restoredAttachment.engine(store: store, device: RuntimeFixture.tablet, trustedClock: clock).start()

    #expect(bootstrap == .reminted(from: original, reason: .markerMissing))
    #expect(store.replica != original)
  }

  @Test("should stay turned off after a detach, even after an account switch, without touching storage")
  func detachSticksAfterAccountSwitch() async throws {
    let provider = InMemoryStorageProvider()
    let account = AccountSwitch(.available(Self.userOne))
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider, account: account)
    let vault = try Self.vault(of: try await device.startup.evaluate())
    account.set(.available(Self.userTwo))
    #expect(try await device.startup.evaluate().phase == .accountChanged)

    try await device.startup.detach()
    let before = provider.callCounts

    #expect(try await device.startup.evaluate().phase == .detached)
    #expect(try await device.startup.evaluate().phase == .detached)
    #expect(provider.callCounts == before)
    #expect(try await RuntimeFixture.hint(in: provider) == vault)
  }

  @Test("should never attach an account-distinguishing provider without knowing the account")
  func requiresBinding() async throws {
    let provider = InMemoryStorageProvider()
    let device = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: provider, account: AccountSwitch(.available(nil)))

    #expect(try await device.startup.evaluate().phase == .accountUnavailable)
    #expect(provider.isUntouched)
    for settings in [RuntimeFixture.iCloud, try Self.oneDrive()] {
      await #expect(throws: SyncStartupError.accountUnavailable) { try await device.startup.attach(settings, choice: .create) }
    }
    #expect(try device.directory.locationStore().load() == .firstUse)

    try device.directory.locationStore().save(SyncLocation(settings: RuntimeFixture.iCloud, vault: RuntimeFixture.vault("vault-one"), account: nil))
    #expect(try await device.startup.evaluate().phase == .accountUnavailable)
    #expect(provider.isUntouched)
  }

  @Test("should clear a corrupt device marker once unlocked so the replica is re-minted")
  func corruptMarker() async throws {
    let keychain = InMemoryKeychain()
    let provider = InMemoryStorageProvider()
    let store = try RuntimeFixture.openStore()
    let clock = TrustedClock(wallClock: { RuntimeFixture.start })
    let device = try RuntimeDevice(keychain.device("phone"), provider: provider)
    let attachment = try #require(try await device.startup.evaluate().attachment)
    _ = try await attachment.engine(store: store, device: RuntimeFixture.phone, trustedClock: clock).start()
    let original = store.replica
    let markerStore = RuntimeFixture.stores(device.keychain).marker
    try markerStore.setData(Data([0xFF, 0x00]), forKey: DeviceMarker.itemName(vault: attachment.vault))

    let result = try await device.startup.evaluate()

    #expect(result.phase.canSync)
    #expect(try markerStore.data(forKey: DeviceMarker.itemName(vault: attachment.vault)) == nil)
    let restarted = try await #require(result.attachment).engine(store: store, device: RuntimeFixture.phone, trustedClock: clock).start()
    #expect(restarted == .reminted(from: original, reason: .markerMissing))
  }

  @Test("should report a locked device when the device marker cannot be read yet")
  func lockedMarker() async throws {
    let keychain = InMemoryKeychain()
    let provider = InMemoryStorageProvider()
    let phone = try RuntimeDevice(keychain.device("phone"), provider: provider)
    _ = try await phone.startup.evaluate()
    keychain.deliver()
    let unlocked = RuntimeFixture.stores(keychain.device("tablet"))
    let stores = SyncSecureStores(ring: unlocked.ring, credentials: unlocked.credentials, marker: LockedSecureStore(), tokens: unlocked.tokens)
    let tablet = try RuntimeDevice(keychain.device("tablet"), provider: provider, stores: stores)

    let result = try await tablet.startup.evaluate()

    #expect(result.phase == .deviceLocked)
    #expect(result.attachment == nil)
  }

  @Test("should map sync failures to the phases they cause")
  func phaseForFailure() {
    #expect(SyncPhase(failure: .storage(.unauthenticated)) == .accountUnavailable)
    #expect(SyncPhase(failure: .appUpdateRequired(minimumSchema: 3, current: 2)) == .appUpdateRequired)
    #expect(SyncPhase(failure: .keyRing(.deviceLocked)) == .deviceLocked)
    #expect(SyncPhase(failure: .lifecycle(.markerUnavailable)) == nil)
    #expect(SyncPhase(failure: .keyRing(.store("secure_store.unexpected_status -25308"))) == nil)
    #expect(SyncPhase(failure: .storage(.unavailable("offline"))) == nil)
    #expect(SyncPhase.vault(.ready(vault: RuntimeFixture.vault("v"))).canSync)
    #expect(!SyncPhase.accountChanged.canSync)
  }
}
