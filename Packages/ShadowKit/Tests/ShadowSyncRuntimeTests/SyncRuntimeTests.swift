import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncCloudKit
import ShadowTestSupport
import Testing

@testable import ShadowSyncRuntime

@Suite("SyncRuntime", TestTimeLimit.standard)
struct SyncRuntimeTests {
  private static func waiters(_ count: Int, on runtime: SyncRuntime) async throws -> Bool {
    for _ in 0..<1_000 {
      if await runtime.exclusiveWaiterCount == count { return true }
      try await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  private static func started(_ provider: any StorageProvider = ControlledProvider(), account: AccountSwitch? = nil) async throws -> RuntimeHarness {
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: provider, account: account ?? AccountSwitch(.available(RuntimeHarness.userOne)))
    await harness.runtime.start()
    await harness.runtime.foreground()
    return harness
  }

  @Test("should report off, then syncing on launch, up to date after it, and syncing again until a write is uploaded")
  func statusOrder() async throws {
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: ControlledProvider())
    defer { Task { await harness.runtime.shutdown() } }
    var updates = harness.runtime.statusUpdates().makeAsyncIterator()
    #expect(await updates.next() == .off)

    await harness.runtime.start()
    #expect(await updates.next() == .syncing)
    #expect(await updates.next() == .upToDate)

    await harness.runtime.foreground()
    #expect(await updates.next() == .syncing)
    #expect(await updates.next() == .upToDate)

    try await harness.write("n1")
    #expect(await updates.next() == .syncing)
    await harness.advance(by: .seconds(2))
    #expect(await updates.next() == .upToDate)
    #expect(try await !harness.hasPendingChanges())
  }

  @Test("should stay off and touch nothing on launch while sync is turned off")
  func staysOff() async throws {
    let provider = ControlledProvider()
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: provider)
    try harness.directory.locationStore().turnOff()
    var updates = harness.runtime.statusUpdates().makeAsyncIterator()

    await harness.runtime.start()
    await harness.runtime.foreground()
    try await harness.write("n1")
    await harness.advance(by: .seconds(60))
    await harness.runtime.shutdown()

    #expect(await updates.next() == .off)
    #expect(await updates.next() == nil)
    #expect(await harness.runtime.currentPhase == .detached)
    #expect(provider.inner.isUntouched)
  }

  @Test("should download every 45 seconds while in front, stop every timer in the background and sync again on foreground")
  func pollsInFront() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    defer { Task { await harness.runtime.shutdown() } }
    let before = provider.downloads

    harness.clock.advance(by: .seconds(44))
    try await harness.quiesce()
    #expect(provider.downloads == before)
    #expect(try await harness.advanceTimer(by: .seconds(1)) { provider.downloads == before + 1 })
    #expect(try await harness.advanceTimer(by: .seconds(45)) { provider.downloads == before + 2 })

    await harness.runtime.background()
    #expect(harness.clock.sleeperCount == 0)
    harness.clock.advance(by: .seconds(450))
    try await harness.quiesce()
    #expect(provider.downloads == before + 2)

    await harness.runtime.foreground()
    #expect(provider.downloads == before + 3)
    #expect(try await harness.advanceTimer(by: .seconds(45)) { provider.downloads == before + 4 })
  }

  @Test("should sync on a change notice from the provider")
  func syncsOnNotice() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    defer { Task { await harness.runtime.shutdown() } }
    let before = provider.downloads

    provider.notify()

    #expect(try await harness.eventually { provider.downloads == before + 1 })
    await harness.runtime.changeNotice()
    #expect(provider.downloads == before + 2)
  }

  @Test("should upload two seconds after the last local write and not before")
  func debouncesUploads() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    defer { Task { await harness.runtime.shutdown() } }
    let before = provider.replicaPuts

    try await harness.write("n1")
    harness.clock.advance(by: .seconds(1))
    try await harness.quiesce()
    try await harness.write("n2")
    harness.clock.advance(by: .milliseconds(1_500))
    try await harness.quiesce()
    #expect(provider.replicaPuts == before)
    #expect(try await harness.hasPendingChanges())

    #expect(try await harness.advanceTimer(by: .milliseconds(500)) { provider.replicaPuts > before })
    #expect(try await !harness.hasPendingChanges())
  }

  @Test("should run once for a write whose earlier timer was superseded, even when that timer still wakes")
  func supersededTimer() async throws {
    let provider = ControlledProvider()
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: provider, clock: ManualClock(wakesCancelledSleepers: true))
    defer { Task { await harness.runtime.shutdown() } }
    await harness.runtime.start()
    await harness.runtime.foreground()
    let runs = await harness.runtime.completedRuns
    let puts = provider.replicaPuts

    try await harness.write("n1")
    harness.clock.advance(by: .seconds(1))
    try await harness.quiesce()
    try await harness.write("n2")
    harness.clock.advance(by: .seconds(1))
    try await harness.quiesce()

    #expect(await harness.runtime.completedRuns == runs)
    #expect(provider.replicaPuts == puts)
    #expect(try await harness.advanceTimer(by: .seconds(1)) { provider.replicaPuts > puts })
    try await harness.quiesce()
    #expect(await harness.runtime.completedRuns == runs + 1)
    #expect(try await !harness.hasPendingChanges())
  }

  @Test("should upload what is unsent on going to the background and return once it is")
  func uploadsOnBackground() async throws {
    let harness = try await Self.started()
    defer { Task { await harness.runtime.shutdown() } }
    try await harness.write("n1")

    await harness.runtime.background()

    #expect(try await !harness.hasPendingChanges())
    #expect(harness.runtime.status == .upToDate)
  }

  @Test("should wait as long as storage asks after a rate limit, even on foreground")
  func honoursRetryAfter() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    defer { Task { await harness.runtime.shutdown() } }
    let before = provider.downloads
    provider.fail(.list, with: .rateLimited(retryAfter: .seconds(120)))

    await harness.advance(by: .seconds(45))
    #expect(provider.downloads == before + 1)
    #expect(harness.runtime.status == .syncing)

    await harness.advance(by: .seconds(45))
    await harness.runtime.foreground()
    await harness.advance(by: .seconds(74))
    #expect(provider.downloads == before + 1)

    await harness.advance(by: .seconds(1))
    #expect(provider.downloads == before + 2)
    #expect(harness.runtime.status == .upToDate)
  }

  @Test("should back off on unavailable storage, ask for attention after repeated failures and recover")
  func backsOff() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    defer { Task { await harness.runtime.shutdown() } }
    let before = provider.downloads
    provider.fail(.list, with: .unavailable("offline"), times: 4)

    #expect(try await harness.advanceTimer(by: .seconds(45)) { provider.downloads == before + 1 })
    harness.clock.advance(by: .milliseconds(1_999))
    try await harness.quiesce()
    #expect(provider.downloads == before + 1)
    #expect(try await harness.advanceTimer(by: .milliseconds(1)) { provider.downloads == before + 2 })
    #expect(harness.runtime.status == .syncing)

    #expect(try await harness.advanceTimer(by: .seconds(4)) { provider.downloads == before + 3 })
    #expect(harness.runtime.status == .attentionNeeded(.storageUnreachable))

    harness.clock.advance(by: .seconds(7))
    try await harness.quiesce()
    #expect(provider.downloads == before + 3)
    #expect(try await harness.advanceTimer(by: .seconds(1)) { provider.downloads == before + 4 })
    #expect(try await harness.advanceTimer(by: .seconds(16)) { provider.downloads == before + 5 })
    #expect(harness.runtime.status == .upToDate)
  }

  @Test("should still upload on going to the background right after a failed attempt")
  func uploadsOnBackgroundAfterFailure() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    defer { Task { await harness.runtime.shutdown() } }
    let before = provider.downloads
    provider.fail(.list, with: .unavailable("offline"))
    #expect(try await harness.advanceTimer(by: .seconds(45)) { provider.downloads == before + 1 })

    try await harness.write("n1")
    await harness.runtime.background()

    #expect(provider.downloads == before + 2)
    #expect(try await !harness.hasPendingChanges())
  }

  @Test("should never run two syncs at once and merge every request made during a run into one more run")
  func singleFlight() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    defer { Task { await harness.runtime.shutdown() } }
    let before = provider.downloads
    provider.holdNext(.download)

    let first = Task { await harness.runtime.changeNotice() }
    await provider.waitUntilHeld()
    await harness.runtime.noteChange()
    await harness.runtime.noteChange()
    try await harness.write("n1")
    await harness.runtime.noteChange()
    provider.releaseHeld()
    await first.value

    #expect(provider.downloads == before + 2)
    #expect(provider.maximumInFlight == 1)
    #expect(try await !harness.hasPendingChanges())
  }

  @Test("should run attach and detach only after the run in flight, release the lock when attach throws, and run nothing after the detach")
  func exclusiveCallsWaitForRun() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    defer { Task { await harness.runtime.shutdown() } }
    guard case .vault(.ready(let vault)) = await harness.runtime.currentPhase else { throw RuntimeFixtureFailure("expected a ready vault") }
    let runs = await harness.runtime.completedRuns
    let downloads = provider.downloads
    provider.holdNext(.download)

    let held = Task { await harness.runtime.changeNotice() }
    await provider.waitUntilHeld()
    let attach = Task { () async -> SyncStartupError? in
      do throws(SyncStartupError) {
        _ = try await harness.runtime.attach(RuntimeFixture.iCloud, choice: .join(RuntimeFixture.vault("vault-other")))
        return nil
      } catch {
        return error
      }
    }
    #expect(try await Self.waiters(1, on: harness.runtime))
    let detach = Task { () async -> SyncStartupError? in
      do throws(SyncStartupError) {
        try await harness.runtime.detach()
        return nil
      } catch {
        return error
      }
    }
    #expect(try await Self.waiters(2, on: harness.runtime))
    guard case .attached = try harness.directory.locationStore().load() else { throw RuntimeFixtureFailure("detached during the run") }

    provider.releaseHeld()
    await held.value
    #expect(await attach.value == .alreadyAttached)
    #expect(await detach.value == nil)

    #expect(try harness.directory.locationStore().load() == .turnedOff(.disconnected))
    try await harness.quiesce()
    #expect(await harness.runtime.completedRuns == runs + 1)
    #expect(provider.downloads == downloads + 1)

    #expect(try await harness.runtime.attach(RuntimeFixture.iCloud, choice: .join(vault)) == .vault(.ready(vault: vault)))
    await harness.runtime.settle()
    #expect(provider.downloads == downloads + 2)
    #expect(harness.runtime.status == .upToDate)
  }

  @Test("should let a pending background call return only after its upload in flight, even across a shutdown")
  func shutdownWaitsForUpload() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    try await harness.write("n1")
    provider.holdNext(.replicaPut)
    let returned = Flag(false)

    let background = Task {
      await harness.runtime.background()
      returned.set(true)
    }
    await provider.waitUntilHeld()
    await harness.runtime.shutdown()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!returned.isSet)

    provider.releaseHeld()
    await background.value

    #expect(returned.isSet)
    #expect(try await !harness.hasPendingChanges())
  }

  @Test("should ask for attention when storage is full, keep downloading, and clear once an upload goes through")
  func quotaFull() async throws {
    let provider = ControlledProvider()
    let harness = try await Self.started(provider)
    defer { Task { await harness.runtime.shutdown() } }
    provider.failPuts(with: .quotaExceeded)

    try await harness.write("n1")
    await harness.advance(by: .seconds(2))
    #expect(harness.runtime.status == .attentionNeeded(.quotaFull))
    #expect(SyncAttentionReason.quotaFull.stops == .uploads)

    let before = provider.downloads
    await harness.advance(by: .seconds(45))
    #expect(provider.downloads == before + 1)
    #expect(harness.runtime.status == .attentionNeeded(.quotaFull))

    provider.failPuts(with: nil)
    await harness.advance(by: .seconds(45))
    #expect(harness.runtime.status == .upToDate)
    #expect(try await !harness.hasPendingChanges())
  }

  @Test("should name the replica whose key has not arrived and clear once it does")
  func namesMissingKey() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try RuntimeHarness(keychain.device("phone"), provider: ControlledProvider(inner: shared))
    defer { Task { await phone.runtime.shutdown() } }
    await phone.runtime.start()
    let vault = try #require(try await RuntimeFixture.hint(in: shared))
    try await phone.write("n1")
    await phone.runtime.background()
    #expect(try await !phone.hasPendingChanges())

    let tabletKeys = keychain.device("tablet")
    _ = try KeyRing(vault: vault, store: RuntimeFixture.stores(tabletKeys).ring).createKey()
    let tablet = try RuntimeHarness(tabletKeys, provider: ControlledProvider(inner: shared))
    defer { Task { await tablet.runtime.shutdown() } }
    await tablet.runtime.start()
    await tablet.runtime.foreground()

    let replica = phone.store.replica
    #expect(tablet.runtime.status == .attentionNeeded(.keysMissing(replicas: [replica])))
    #expect(SyncAttentionReason.keysMissing(replicas: [replica]).stops == .downloads(from: [replica]))
    guard case .vault(.partiallyReadable(vault, let missing)) = await tablet.runtime.currentPhase else {
      throw RuntimeFixtureFailure("expected a partially readable vault")
    }
    #expect(Set(missing.values.joined()) == [replica])

    keychain.deliver()
    await tablet.advance(by: .seconds(45))

    #expect(tablet.runtime.status == .upToDate)
  }

  @Test("should seal a key that joins the ring during a download to the active recovery phrase")
  func reconcilesRecoveryAfterNewKey() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try RuntimeHarness(keychain.device("phone"), provider: ControlledProvider(inner: shared))
    defer { Task { await phone.runtime.shutdown() } }
    await phone.runtime.start()
    await phone.runtime.foreground()
    let vault = try #require(try await RuntimeFixture.hint(in: shared))
    let setup = try #require(await phone.runtime.recoverySetup)
    let recipient = try await KeyFixture.commit(setup).outcome.recipientID

    let arrived = try KeyRing(vault: vault, store: RuntimeFixture.stores(keychain.device("phone")).ring).createKey()
    let copy = VaultPath.sealedKey(recipient: recipient, key: arrived.id)
    await #expect(throws: StorageError.notFound(copy)) { try await shared.get(copy) }

    await phone.advance(by: .seconds(45))

    #expect(try await !shared.get(copy).isEmpty)
    #expect(phone.runtime.status == .upToDate)
  }

  @Test("should wait for the vault's key, look for it every 30 seconds and sync once it arrives")
  func awaitsKey() async throws {
    let keychain = InMemoryKeychain()
    let shared = InMemoryStorageProvider()
    let phone = try RuntimeHarness(keychain.device("phone"), provider: ControlledProvider(inner: shared))
    defer { Task { await phone.runtime.shutdown() } }
    await phone.runtime.start()
    let tablet = try RuntimeHarness(keychain.device("tablet"), provider: ControlledProvider(inner: shared))
    defer { Task { await tablet.runtime.shutdown() } }

    await tablet.runtime.start()
    await tablet.runtime.foreground()
    #expect(tablet.runtime.status == .attentionNeeded(.awaitingKey))
    #expect(SyncAttentionReason.awaitingKey.stops == .everything)

    keychain.deliver()
    await tablet.advance(by: .seconds(29))
    #expect(tablet.runtime.status == .attentionNeeded(.awaitingKey))
    await tablet.advance(by: .seconds(1))

    #expect(tablet.runtime.status == .upToDate)
  }

  @Test("should return the vault to device backups on detach and stop syncing")
  func detachClearsBackupFlag() async throws {
    let directory = try TemporaryDirectory()
    let provider = ControlledProvider()
    let harness = try RuntimeHarness(
      InMemoryKeychain().device("phone"), provider: provider, directory: directory, store: try RuntimeHarness.fileStore(in: directory))
    defer { Task { await harness.runtime.shutdown() } }
    let vaultDirectory = RuntimeHarness.vaultDirectory(of: directory)
    await harness.runtime.start()
    await harness.runtime.foreground()
    #expect(try await RuntimeHarness.backupFlagSettles(on: true, vaultDirectory))

    try await harness.runtime.detach()

    #expect(try await RuntimeHarness.backupFlagSettles(on: false, vaultDirectory))
    #expect(harness.runtime.status == .off)
    #expect(await harness.runtime.currentPhase == .detached)
    let puts = provider.replicaPuts
    try await harness.write("n1")
    await harness.advance(by: .seconds(60))
    await harness.runtime.foreground()
    #expect(provider.replicaPuts == puts)
    #expect(harness.runtime.status == .off)
  }

  @Test("should treat a store pinned out of backups as already detached")
  func detachPinnedStore() async throws {
    let directory = try TemporaryDirectory()
    let harness = try RuntimeHarness(
      InMemoryKeychain().device("phone"), provider: ControlledProvider(), directory: directory,
      store: try RuntimeHarness.fileStore(in: directory, backup: .alwaysExcluded))
    defer { Task { await harness.runtime.shutdown() } }
    await harness.runtime.start()

    try await harness.runtime.detach()

    #expect(BackupExclusion.isExcluded(RuntimeHarness.vaultDirectory(of: directory)))
    #expect(harness.runtime.status == .off)
    #expect(try harness.directory.locationStore().load() == .turnedOff(.disconnected))
  }

  @Test("should stop uploading and return the vault to backups when the account changes")
  func accountChangeStopsUploads() async throws {
    let directory = try TemporaryDirectory()
    let account = AccountSwitch(.available(RuntimeHarness.userOne))
    let provider = ControlledProvider()
    let harness = try RuntimeHarness(
      InMemoryKeychain().device("phone"), provider: provider, account: account, directory: directory, store: try RuntimeHarness.fileStore(in: directory))
    defer { Task { await harness.runtime.shutdown() } }
    await harness.runtime.start()
    await harness.runtime.foreground()
    #expect(try await RuntimeHarness.backupFlagSettles(on: true, RuntimeHarness.vaultDirectory(of: directory)))

    account.set(.available(RuntimeHarness.userTwo))
    await harness.runtime.foreground()

    #expect(harness.runtime.status == .attentionNeeded(.accountChanged))
    #expect(SyncAttentionReason.accountChanged.stops == .everything)
    #expect(try await RuntimeHarness.backupFlagSettles(on: false, RuntimeHarness.vaultDirectory(of: directory)))
    let puts = provider.replicaPuts
    try await harness.write("n1")
    await harness.advance(by: .seconds(60))
    await harness.runtime.background()
    #expect(provider.replicaPuts == puts)
    #expect(try await harness.hasPendingChanges())
  }

  @Test("should report unreadable sync settings apart from a disconnect and sync again once attached")
  func corruptLocation() async throws {
    let harness = try await Self.started()
    defer { Task { await harness.runtime.shutdown() } }
    let vault = try #require(
      try await harness.runtime.currentPhase.flatMap { phase -> VaultID? in
        guard case .vault(.ready(let vault)) = phase else { return nil }
        return vault
      })
    try Data("{".utf8).write(to: try harness.directory.locationStore().url)

    await harness.runtime.foreground()

    #expect(harness.runtime.status == .attentionNeeded(.settingsUnreadable))
    #expect(await harness.runtime.currentPhase == .settingsUnreadable)
    #expect(try await harness.runtime.attach(RuntimeFixture.iCloud, choice: .join(vault)) == .vault(.ready(vault: vault)))
    await harness.runtime.settle()
    #expect(harness.runtime.status == .upToDate)
  }

  @Test("should ask for attention and stop uploads while the store stamps changes with a wrong clock")
  func wrongClock() async throws {
    let serverTime = RuntimeFixture.start.addingTimeInterval(86_400)
    let provider = ControlledProvider(inner: InMemoryStorageProvider(serverClock: { serverTime }))
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: provider)
    defer { Task { await harness.runtime.shutdown() } }
    await harness.runtime.start()
    await harness.runtime.foreground()

    try await harness.write("n1")
    await harness.advance(by: .seconds(2))

    guard case .attentionNeeded(.wrongClock(let skew, stopsUploads: true)) = harness.runtime.status else {
      throw RuntimeFixtureFailure("expected a wrong clock, got \(harness.runtime.status)")
    }
    #expect(skew < .seconds(-86_340) && skew > .seconds(-86_460))
    #expect(try await harness.hasPendingChanges())
  }
}

@Suite("SyncRuntime on iCloud", TestTimeLimit.standard)
struct SyncRuntimeCloudKitTests {
  private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

  enum Loss: Sendable, CaseIterable {
    case zoneDeleted
    case accountSwitched
  }

  @Test("should keep reading the attached provider after looking at another location", arguments: Loss.allCases)
  func discoveryElsewhere(loss: Loss) async throws {
    let zone = FakeCloudKitZone(epoch: Self.epoch)
    let made = Counter()
    let directory = try TemporaryDirectory()
    let harness = try RuntimeHarness(
      InMemoryKeychain().device("phone"),
      makeProvider: { settings in
        guard settings == RuntimeFixture.iCloud else { return InMemoryStorageProvider() }
        made.increment()
        return CloudKitStorageProvider(client: zone, stateStore: InMemoryCloudKitStateStore())
      }, account: AccountSwitch(.available(SyncAccountBinding(kind: .iCloud, account: "user-1"))), directory: directory,
      store: try RuntimeHarness.fileStore(in: directory, wallClock: { Self.epoch }), trustedClock: TrustedClock(wallClock: { Self.epoch }), wallClock: { Self.epoch })
    defer { Task { await harness.runtime.shutdown() } }
    let vaultDirectory = RuntimeHarness.vaultDirectory(of: directory)
    await harness.runtime.start()
    await harness.runtime.foreground()
    #expect(try await RuntimeHarness.backupFlagSettles(on: true, vaultDirectory))

    #expect(try await harness.runtime.discover(RuntimeFixture.localFolder("elsewhere")) == .empty)
    await harness.runtime.foreground()
    #expect(harness.runtime.status == .upToDate)

    let expected: SyncAttentionReason
    switch loss {
    case .zoneDeleted:
      zone.deleteZone(.purged)
      expected = .zoneLost(.purged)
    case .accountSwitched:
      zone.signIn("user-2")
      expected = .accountChanged
    }

    #expect(try await harness.eventually { harness.runtime.status == .attentionNeeded(expected) })
    #expect(try await RuntimeHarness.backupFlagSettles(on: false, vaultDirectory))
    await harness.runtime.foreground()
    #expect(harness.runtime.status == .attentionNeeded(expected))
    #expect(made.value == 1)
  }

  private static func started(_ zone: FakeCloudKitZone) async throws -> RuntimeHarness {
    let provider = CloudKitStorageProvider(client: zone, stateStore: InMemoryCloudKitStateStore())
    let account = AccountSwitch(.available(SyncAccountBinding(kind: .iCloud, account: "user-1")))
    let store = try VaultStore.open(.inMemory, registry: RuntimeFixture.registry, migrations: SyncEngine.migrations, wallClock: { epoch })
    let harness = try RuntimeHarness(
      InMemoryKeychain().device("phone"), provider: provider, account: account, store: store, trustedClock: TrustedClock(wallClock: { epoch }),
      wallClock: { epoch })
    await harness.runtime.start()
    await harness.runtime.foreground()
    return harness
  }

  @Test("should stop uploading as soon as iCloud reports another account")
  func accountSwitchStopsUploads() async throws {
    let zone = FakeCloudKitZone(epoch: Self.epoch)
    let harness = try await Self.started(zone)
    defer { Task { await harness.runtime.shutdown() } }
    try await harness.write("n1")
    await harness.advance(by: .seconds(2))
    #expect(harness.runtime.status == .upToDate)

    zone.signIn("user-2")

    #expect(try await harness.eventually { harness.runtime.status == .attentionNeeded(.accountChanged) })
    let saves = zone.callCount(.save)
    try await harness.write("n2")
    await harness.advance(by: .seconds(60))
    await harness.runtime.background()
    #expect(zone.callCount(.save) == saves)
    #expect(try await harness.hasPendingChanges())
  }

  @Test("should report a deleted zone and never create it again on its own")
  func zoneLost() async throws {
    let zone = FakeCloudKitZone(epoch: Self.epoch)
    let harness = try await Self.started(zone)
    defer { Task { await harness.runtime.shutdown() } }

    zone.deleteZone(.purged)

    #expect(try await harness.eventually { harness.runtime.status == .attentionNeeded(.zoneLost(.purged)) })
    try await harness.write("n1")
    await harness.advance(by: .seconds(60))
    await harness.runtime.foreground()
    #expect(harness.runtime.status == .attentionNeeded(.zoneLost(.purged)))
    #expect(!zone.zoneExists)
  }
}
