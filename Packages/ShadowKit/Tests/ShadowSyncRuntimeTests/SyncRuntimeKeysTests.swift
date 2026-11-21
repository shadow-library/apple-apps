import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncRuntime

@Suite("SyncRuntime key services", TestTimeLimit.standard)
struct SyncRuntimeKeysTests {
  private static func holder(
    _ keychain: InMemoryKeychain, provider: any StorageProvider, account: AccountSwitch = AccountSwitch(.available(RuntimeHarness.userOne))
  ) async throws -> RuntimeHarness {
    let phone = try RuntimeHarness(keychain.device("phone"), provider: provider, account: account)
    await phone.runtime.start()
    await phone.runtime.foreground()
    try await phone.write("n1")
    await phone.advance(by: .seconds(2))
    return phone
  }

  private static func newcomer(_ keychain: InMemoryKeychain, provider: any StorageProvider) async throws -> RuntimeHarness {
    let tablet = try RuntimeHarness(keychain.device("tablet"), provider: provider)
    await tablet.runtime.start()
    await tablet.runtime.foreground()
    return tablet
  }

  private static func commit(_ access: SyncKeyAccess) async throws -> (phrase: RecoveryPhrase, outcome: RecoverySetupOutcome) {
    let pending = access.beginRecoveryPhrase()
    let phrase = try KeyFixture.phrase(of: pending)
    return (phrase, try await access.commitRecoveryPhrase(pending, confirming: try KeyFixture.confirmation(for: pending)))
  }

  /// Nil when the runtime refused because sync was turned off, which is the only refusal a disconnect may cause.
  private static func keyServicesUnlessDetached(_ runtime: SyncRuntime) async -> SyncKeyAccess? {
    do {
      return try await runtime.keyServices()
    } catch {
      #expect(error == .unavailable(.detached))
      return nil
    }
  }

  private static func becomesUpToDate(_ harness: RuntimeHarness) async -> Bool {
    await harness.runtime.idle()
    return harness.runtime.status == .upToDate
  }

  @Test("should bring a device awaiting its key to ready once it recovers the vault by phrase")
  func recoversByPhrase() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try await Self.holder(keychain, provider: shared)
    defer { Task { await phone.runtime.shutdown() } }
    let holding = try await phone.runtime.keyServices()
    #expect(holding.holdsKey)
    let (phrase, _) = try await Self.commit(holding)

    let tablet = try await Self.newcomer(keychain, provider: shared)
    defer { Task { await tablet.runtime.shutdown() } }
    #expect(tablet.runtime.status == .attentionNeeded(.awaitingKey))
    let waiting = try await tablet.runtime.keyServices()
    #expect(!waiting.holdsKey && waiting.vault == holding.vault)
    await #expect(throws: RecoveryError.noRingKey) { try await Self.commit(waiting) }

    let imported = try await waiting.recover(with: phrase)
    #expect(imported.added.count == 1 && imported.unconfirmed.isEmpty)
    #expect(waiting.holdsKey)
    #expect(await Self.becomesUpToDate(tablet))
    #expect(await tablet.runtime.currentPhase == .vault(.ready(vault: holding.vault)))
    #expect(try await Self.commit(waiting).outcome.sealed == imported.added)
  }

  @Test("should stay awaiting the key and report why when the phrase is wrong")
  func wrongPhrase() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try await Self.holder(keychain, provider: shared)
    defer { Task { await phone.runtime.shutdown() } }
    let vault = try await phone.runtime.keyServices().vault
    _ = try await Self.commit(try await phone.runtime.keyServices())
    let tablet = try await Self.newcomer(keychain, provider: shared)
    defer { Task { await tablet.runtime.shutdown() } }

    let stranger = try RecoveryPhrase(parsing: RecoveryPhrase(secret: .generate()).words.joined(separator: " "))
    await #expect(throws: RecoveryError.noRecoveryCopies) { try await tablet.runtime.keyServices().recover(with: stranger) }

    await tablet.runtime.idle()
    #expect(tablet.runtime.status == .attentionNeeded(.awaitingKey))
    #expect(await tablet.runtime.currentPhase == .vault(.awaitingKey(vault: vault)))
  }

  @Test("should make a device awaiting its key ready once a holder answers its QR code and the codes match")
  func exchangesByQR() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try await Self.holder(keychain, provider: shared)
    defer { Task { await phone.runtime.shutdown() } }
    let vault = try await phone.runtime.keyServices().vault
    let tablet = try await Self.newcomer(keychain, provider: shared)
    defer { Task { await tablet.runtime.shutdown() } }

    let request = try await tablet.runtime.keyServices().requestKeys()
    let responder = try await phone.runtime.keyServices().respond(to: request.payload)
    let shown = try request.receive(responder.payload)
    #expect(tablet.runtime.status == .attentionNeeded(.awaitingKey))
    let imported = try await request.accept(confirmingCode: responder.revealConfirmationCode())

    #expect(shown.count == 6 && imported.added.count == 1)
    #expect(await Self.becomesUpToDate(tablet))
    #expect(await tablet.runtime.currentPhase == .vault(.ready(vault: vault)))
  }

  @Test("should keep a device awaiting its key when the codes differ")
  func exchangeCodeMismatch() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try await Self.holder(keychain, provider: shared)
    defer { Task { await phone.runtime.shutdown() } }
    let tablet = try await Self.newcomer(keychain, provider: shared)
    defer { Task { await tablet.runtime.shutdown() } }

    let request = try await tablet.runtime.keyServices().requestKeys()
    let responder = try await phone.runtime.keyServices().respond(to: request.payload)
    let shown = try request.receive(responder.payload)

    await #expect(throws: KeyExchangeError.codeMismatch) { try await request.accept(confirmingCode: shown == "000000" ? "111111" : "000000") }
    await tablet.runtime.idle()
    #expect(tablet.runtime.status == .attentionNeeded(.awaitingKey))
  }

  @Test("should send the keys at or above the vault's key floor first when it answers a request")
  func respondsWithTheKeyFloor() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try await Self.holder(keychain, provider: shared)
    defer { Task { await phone.runtime.shutdown() } }
    let holding = try await phone.runtime.keyServices()
    let ring = KeyRing(vault: holding.vault, store: keychain.device("phone").store(service: RuntimeFixture.ringService, scope: .synced))
    let keys = (1...18).map(KeyFixture.key)
    for key in keys { try ring.add(key) }
    try await KeyFixture.putHeldFile(sealedWith: keys[17], vault: holding.vault, in: shared)
    try await phone.store.write { transaction in
      let directory = try ReplicaDirectory.read(in: transaction)
      try directory.raiseKeyFloor(to: RuntimeFixture.keyID(10), in: &transaction)
    }
    let tablet = try await Self.newcomer(keychain, provider: shared)
    defer { Task { await tablet.runtime.shutdown() } }

    let request = try await tablet.runtime.keyServices().requestKeys()
    let responder = try await holding.respond(to: request.payload)
    _ = try request.receive(responder.payload)
    let imported = try await request.accept(confirmingCode: responder.revealConfirmationCode())

    #expect(imported.added.contains(RuntimeFixture.keyID(18)))
  }

  @Test("should report a phrase another device replaced after the one the user wrote down")
  func supersededPhrase() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try await Self.holder(keychain, provider: shared)
    defer { Task { await phone.runtime.shutdown() } }
    let tablet = try RuntimeHarness(keychain.device("tablet"), provider: shared, wallClock: { RuntimeFixture.start.addingTimeInterval(60) })
    defer { Task { await tablet.runtime.shutdown() } }
    keychain.deliver()
    await tablet.runtime.start()
    await tablet.runtime.foreground()
    #expect(await Self.becomesUpToDate(tablet))

    let setup = try await phone.runtime.keyServices()
    let (_, first) = try await Self.commit(setup)
    #expect(try await setup.recoveryStatus().standing(ofRecipient: first.recipientID) == .active(createdMillis: 1_700_000_000_000))
    let (_, second) = try await Self.commit(try await tablet.runtime.keyServices())
    #expect(first.recipientID != second.recipientID)

    await tablet.runtime.localWrite()
    await tablet.advance(by: .seconds(2))
    await phone.advance(by: .seconds(45))
    let standing = try await setup.recoveryStatus().standing(ofRecipient: first.recipientID)

    #expect(standing == .replaced(byRecipientID: second.recipientID))
    #expect(try await setup.recoveryStatus().standing(ofRecipient: second.recipientID) == .active(createdMillis: 1_700_000_060_000))
    #expect(try await setup.recoveryStatus().standing(ofRecipient: nil) == .active(createdMillis: 1_700_000_060_000))
  }

  @Test("should have no key services before the runtime evaluates or while no vault is attached")
  func unavailableKeyServices() async throws {
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: InMemoryStorageProvider())
    defer { Task { await harness.runtime.shutdown() } }
    await #expect(throws: SyncStartupError.notAttached) { try await harness.runtime.keyServices() }

    await harness.runtime.start()
    _ = try await harness.runtime.keyServices()
    try await harness.runtime.detach()
    await #expect(throws: SyncStartupError.unavailable(.detached)) { try await harness.runtime.keyServices() }
  }

  @Test("should refuse key services held across a disconnect, or opened while it runs, without reaching storage")
  func refusesAfterDetach() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try await Self.holder(keychain, provider: shared)
    defer { Task { await phone.runtime.shutdown() } }
    let held = try await phone.runtime.keyServices()
    let (phrase, _) = try await Self.commit(held)

    async let detaching: Void = phone.runtime.detach()
    async let opened = Self.keyServicesUnlessDetached(phone.runtime)
    try await detaching
    let accesses = [held] + [await opened].compactMap(\.self)
    let before = shared.callCounts

    for access in accesses {
      let request = access.requestKeys()
      await #expect(throws: RecoveryError.unavailable(.detached)) { try await access.recover(with: phrase) }
      await #expect(throws: RecoveryError.unavailable(.detached)) { try await access.recoveryStatus() }
      await #expect(throws: RecoveryError.unavailable(.detached)) { try await access.commitRecoveryPhrase(access.beginRecoveryPhrase(), confirming: [:]) }
      await #expect(throws: KeyExchangeError.unavailable(.detached)) { try await access.respond(to: request.payload) }
      await #expect(throws: KeyExchangeError.unavailable(.detached)) { try await request.accept(confirmingCode: "000000") }
    }
    #expect(shared.callCounts == before)
    await #expect(throws: SyncStartupError.unavailable(.detached)) { try await phone.runtime.keyServices() }
  }

  @Test("should refuse key services held across an account change until the account the vault was attached with returns")
  func refusesAfterAccountChange() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let account = AccountSwitch(.available(RuntimeHarness.userOne))
    let phone = try await Self.holder(keychain, provider: shared, account: account)
    defer { Task { await phone.runtime.shutdown() } }
    let held = try await phone.runtime.keyServices()
    let (phrase, outcome) = try await Self.commit(held)

    account.set(.available(RuntimeHarness.userTwo))
    await phone.runtime.foreground()
    #expect(await phone.runtime.currentPhase == .accountChanged)
    let before = shared.callCounts

    await #expect(throws: RecoveryError.unavailable(.accountChanged)) { try await held.recover(with: phrase) }
    await #expect(throws: KeyExchangeError.unavailable(.accountChanged)) { try await held.respond(to: held.requestKeys().payload) }
    #expect(shared.callCounts == before)

    account.set(.available(RuntimeHarness.userOne))
    await phone.runtime.foreground()
    #expect(try await held.recoveryStatus().standing(ofRecipient: outcome.recipientID) == .active(createdMillis: 1_700_000_000_000))
  }

  @Test("should run once when keys arrive with a key check pending, and give imports during a run one follow-up")
  func keysImportedCoalesces() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try await Self.holder(keychain, provider: shared)
    defer { Task { await phone.runtime.shutdown() } }
    let (phrase, _) = try await Self.commit(try await phone.runtime.keyServices())
    let tablet = try await Self.newcomer(keychain, provider: shared)
    defer { Task { await tablet.runtime.shutdown() } }
    let runs = await tablet.runtime.completedRuns

    _ = try await tablet.runtime.keyServices().recover(with: phrase)
    await tablet.runtime.idle()
    await tablet.advance(by: .seconds(30))
    #expect(await tablet.runtime.completedRuns == runs + 1)
    #expect(tablet.runtime.status == .upToDate)

    let settled = await tablet.runtime.completedRuns
    await tablet.runtime.keysImported()
    await tablet.runtime.keysImported()
    await tablet.runtime.keysImported()
    await tablet.runtime.idle()
    #expect(await tablet.runtime.completedRuns == settled + 2)
  }

  @Test("should report that sync needs a signed build when the keychain refuses a new vault's key")
  func keychainRefusesNewVault() async throws {
    let keychain = InMemoryKeychain().device("phone")
    let healthy = RuntimeFixture.stores(keychain)
    let stores = SyncSecureStores(ring: MissingEntitlementSecureStore(), credentials: healthy.credentials, marker: healthy.marker, tokens: healthy.tokens)
    let harness = try RuntimeHarness(keychain, provider: InMemoryStorageProvider(), stores: stores)
    defer { Task { await harness.runtime.shutdown() } }

    await harness.runtime.start()
    await harness.runtime.foreground()

    #expect(harness.runtime.status == .attentionNeeded(.keychainUnavailable))
    #expect(SyncAttentionReason.keychainUnavailable.stops == .everything)
    #expect(await harness.runtime.currentPhase == .keychainUnavailable)
    await #expect(throws: SyncStartupError.unavailable(.keychainUnavailable)) { try await harness.runtime.keyServices() }
  }

  @Test("should report that sync needs a signed build, not a missing key, when a team-less build first meets a vault")
  func keychainRefusesFirstJoin() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try await Self.holder(keychain, provider: shared)
    defer { Task { await phone.runtime.shutdown() } }
    let before = shared.callCounts
    let tablet = try RuntimeHarness(keychain.device("tablet"), provider: shared, stores: MissingEntitlementSecureStore.stores())
    defer { Task { await tablet.runtime.shutdown() } }

    await tablet.runtime.start()

    #expect(tablet.runtime.status == .attentionNeeded(.keychainUnavailable))
    #expect(await tablet.runtime.currentPhase == .keychainUnavailable)
    #expect(shared.callCounts == before)
  }

  @Test("should report that sync needs a signed build before it makes the provider of an attached vault")
  func keychainRefusesAttachedVault() async throws {
    let keychain = InMemoryKeychain().device("phone")
    let provider = InMemoryStorageProvider()
    let directory = try TemporaryDirectory()
    let first = try RuntimeHarness(keychain, provider: provider, directory: directory)
    await first.runtime.start()
    await first.runtime.shutdown()

    let madeProvider = Flag(false)
    let second = try RuntimeHarness(
      keychain,
      makeProvider: { _ in
        madeProvider.set(true)
        return provider
      }, directory: directory, stores: MissingEntitlementSecureStore.stores())
    defer { Task { await second.runtime.shutdown() } }
    await second.runtime.start()

    #expect(second.runtime.status == .attentionNeeded(.keychainUnavailable))
    #expect(await second.runtime.currentPhase == .keychainUnavailable)
    #expect(!madeProvider.isSet)
  }

  @Test("should report that sync needs a signed build when only the ring's keychain refuses to be read")
  func keychainRefusesRingRead() async throws {
    let keychain = InMemoryKeychain().device("phone")
    let healthy = RuntimeFixture.stores(keychain)
    let provider = InMemoryStorageProvider()
    let directory = try TemporaryDirectory()
    let first = try RuntimeHarness(keychain, provider: provider, directory: directory)
    await first.runtime.start()
    await first.runtime.shutdown()

    let stores = SyncSecureStores(
      ring: MissingEntitlementSecureStore(refusesReads: true), credentials: healthy.credentials, marker: healthy.marker, tokens: healthy.tokens)
    let second = try RuntimeHarness(keychain, provider: provider, directory: directory, stores: stores)
    defer { Task { await second.runtime.shutdown() } }
    await second.runtime.start()

    #expect(second.runtime.status == .attentionNeeded(.keychainUnavailable))
    #expect(await second.runtime.currentPhase == .keychainUnavailable)
  }

  @Test("should not retry a keychain that refuses the build until the app comes to the front again")
  func keychainRefusalWaitsForForeground() async throws {
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: InMemoryStorageProvider(), stores: MissingEntitlementSecureStore.stores())
    defer { Task { await harness.runtime.shutdown() } }
    await harness.runtime.start()
    let runs = await harness.runtime.completedRuns

    await harness.advance(by: .seconds(31))
    await harness.advance(by: .seconds(400))

    #expect(await harness.runtime.completedRuns == runs)
    #expect(harness.runtime.status == .attentionNeeded(.keychainUnavailable))
    await harness.runtime.foreground()
    #expect(await harness.runtime.completedRuns == runs + 1)
    #expect(harness.runtime.status == .attentionNeeded(.keychainUnavailable))
  }

  @Test("should throw a keychain error from an explicit create or join that the keychain refuses, touching no storage")
  func keychainRefusesAttach() async throws {
    let keychain = InMemoryKeychain()
    let provider = InMemoryStorageProvider()
    let folder = RuntimeFixture.localFolder("one")
    let healthy = try RuntimeDevice(keychain.device("phone"), provider: provider, automatic: nil)
    let vault = try #require(try await healthy.startup.attach(folder, choice: .create).location?.vault)
    let healthyStores = RuntimeFixture.stores(keychain.device("tablet"))
    let ringRefusing = SyncSecureStores(
      ring: MissingEntitlementSecureStore(), credentials: healthyStores.credentials, marker: healthyStores.marker, tokens: healthyStores.tokens)
    let creator = try RuntimeDevice(keychain.device("tablet"), provider: InMemoryStorageProvider(), automatic: nil, stores: ringRefusing)
    let joiner = try RuntimeDevice(keychain.device("laptop"), provider: provider, automatic: nil, stores: MissingEntitlementSecureStore.stores())
    let before = provider.callCounts

    await #expect(throws: SyncStartupError.keychainUnavailable) { try await creator.startup.attach(folder, choice: .create) }
    await #expect(throws: SyncStartupError.keychainUnavailable) { try await joiner.startup.attach(folder, choice: .join(vault)) }
    #expect(provider.callCounts == before)
    #expect(try joiner.directory.locationStore().load() == .firstUse)
  }

}
