import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import Testing

@Suite("RecoverySetup", TestTimeLimit.quick)
struct RecoverySetupTests {
  private static func device(_ provider: any StorageProvider = InMemoryStorageProvider(), keys: [VaultKey] = [KeyFixture.key(1)]) throws -> KeyDevice {
    let device = try KeyDevice(InMemoryKeychain().device("phone"), vault: KeyFixture.vault, provider: provider)
    for key in keys { try device.ring.add(key) }
    return device
  }

  private static func listed(_ recipientID: String, in provider: any StorageProvider) async throws -> [KeyID] {
    try await KeyFixture.copies(of: recipientID, in: provider).compactMap { key in
      guard case .sealedKey(_, let keyID) = VaultPath.classify(key) else { return nil }
      return keyID
    }
  }

  @Test("should set up a phrase on one device and bring the vault to a fresh device with it")
  func endToEnd() async throws {
    let keychain = InMemoryKeychain()
    let provider = InMemoryStorageProvider()
    let clock = TrustedClock(wallClock: { RuntimeFixture.start })
    let phone = try RuntimeDevice(keychain.device("phone"), provider: provider)
    let phoneAttachment = try #require(try await phone.startup.evaluate().attachment)
    let phoneStore = try RuntimeFixture.openStore()
    let phoneEngine = phoneAttachment.engine(store: phoneStore, device: RuntimeFixture.phone, trustedClock: clock)
    _ = try await phoneEngine.start()
    let note = EntityRef(kind: RuntimeFixture.note, key: try #require(EntityKey("note-one")))
    try await phoneStore.write { transaction in _ = try transaction.set(note, ["title": .string("Chapter one")]) }
    let (phrase, outcome) = try await KeyFixture.commit(phoneAttachment.recoverySetup(store: phoneStore, wallClock: { RuntimeFixture.start }))
    _ = try await phoneEngine.upload()
    #expect(outcome.sealed == phoneAttachment.ring.keyIDs && outcome.isComplete && outcome.retiredRecipients.isEmpty)

    let tablet = try RuntimeDevice(keychain.device("tablet"), provider: provider)
    let waiting = try await tablet.startup.evaluate()
    #expect(waiting.phase == .vault(.awaitingKey(vault: phoneAttachment.vault)))
    let tabletAttachment = try #require(waiting.attachment)
    let imported = try await tabletAttachment.phraseRecovery.recover(try RecoveryPhrase(parsing: phrase.words.joined(separator: "  ").uppercased()))

    #expect(imported.added == phoneAttachment.ring.keyIDs && imported.alreadyHeld.isEmpty && imported.unconfirmed.isEmpty && imported.conflicting.isEmpty)
    #expect(try await tablet.startup.evaluate().phase == .vault(.ready(vault: phoneAttachment.vault)))
    let tabletStore = try RuntimeFixture.openStore()
    let tabletEngine = tabletAttachment.engine(store: tabletStore, device: RuntimeFixture.tablet, trustedClock: clock)
    _ = try await tabletEngine.start()
    _ = try await tabletEngine.download()
    #expect(try await tabletStore.read { try $0.state(of: note) } != nil)
    #expect(try await tabletAttachment.recoverySetup(store: tabletStore).status() == .active(recipientID: outcome.recipientID, createdMillis: 1_700_000_000_000))
  }

  @Test("should hand out one recovery setup and one exchange coordinator per attached vault")
  func attachmentOwnsServices() async throws {
    let phone = try RuntimeDevice(InMemoryKeychain().device("phone"), provider: InMemoryStorageProvider())
    let first = try #require(try await phone.startup.evaluate().attachment)
    let second = try #require(try await phone.startup.evaluate().attachment)
    let store = try RuntimeFixture.openStore()

    #expect(first.recoverySetup(store: store) === second.recoverySetup(store: store))
    #expect(first.keyExchange === second.keyExchange)
    #expect(first.recoverySetup(store: store) !== first.recoverySetup(store: try RuntimeFixture.openStore()))

    try await phone.startup.detach()
    try phone.directory.locationStore().save(first.location)
    let reattached = try #require(try await phone.startup.evaluate().attachment)
    #expect(reattached.keyExchange !== first.keyExchange)
  }

  @Test("should record nothing until the confirmation words match, then seal every ring key and record the recipient once")
  func confirmationGatesTheCommit() async throws {
    let provider = InMemoryStorageProvider()
    let device = try Self.device(provider, keys: [KeyFixture.key(1), KeyFixture.key(2)])
    let setup = device.setup()
    let pending = setup.begin()
    var confirmation = try KeyFixture.confirmation(for: pending)
    let wrongPosition = try #require(pending.confirmationPositions.first)
    let words = try KeyFixture.phrase(of: pending).words
    confirmation[wrongPosition] = words[wrongPosition - 1] == "abandon" ? "zoo" : "abandon"

    await #expect(throws: RecoveryError.confirmationMismatch(positions: [wrongPosition])) { try await setup.commit(pending, confirming: confirmation) }
    await #expect(throws: RecoveryError.confirmationMismatch(positions: pending.confirmationPositions)) { try await setup.commit(pending, confirming: [:]) }
    #expect(try await setup.status() == .notSetUp)
    #expect(try await provider.listAll(prefix: "keys/").isEmpty)
    #expect(pending.confirmationPositions.count == PendingRecoveryPhrase.confirmationCount && Set(pending.confirmationPositions).count == 3)

    var spaced = try KeyFixture.confirmation(for: pending)
    for (position, word) in spaced { spaced[position] = " \(word.uppercased())\n" }
    let outcome = try await setup.commit(pending, confirming: spaced)

    #expect(outcome.sealed == [RuntimeFixture.keyID(1), RuntimeFixture.keyID(2)] && outcome.isComplete)
    #expect(try await setup.status() == .active(recipientID: outcome.recipientID, createdMillis: 1_700_000_000_000))
    #expect(try await Self.listed(outcome.recipientID, in: provider) == outcome.sealed)
    #expect(outcome.recipientID == KeyFixture.recipientID(try RecoveryPhrase(parsing: words.joined(separator: " "))))
    #expect(pending.phrase == nil && pending.isRecorded)
    await #expect(throws: RecoveryError.setupFinished) { try await setup.commit(pending, confirming: spaced) }
  }

  @Test("should keep the phrase open when sealing fails part-way and commit the same phrase on retry")
  func partialSealing() async throws {
    let provider = HookedProvider()
    let device = try Self.device(provider, keys: [KeyFixture.key(1), KeyFixture.key(2)])
    let setup = device.setup()
    let failing = RuntimeFixture.keyID(2).description
    provider.update { $0.failPut = { key in key.rawValue.hasSuffix(failing) ? .quotaExceeded : nil } }
    let pending = setup.begin()
    let confirmation = try KeyFixture.confirmation(for: pending)
    let recipientID = KeyFixture.recipientID(try KeyFixture.phrase(of: pending))

    await #expect(throws: RecoveryError.storage(.quotaExceeded)) { try await setup.commit(pending, confirming: confirmation) }
    #expect(try await setup.status() == .notSetUp)
    #expect(!pending.isRecorded)
    #expect(try await Self.listed(recipientID, in: provider) == [RuntimeFixture.keyID(1)])

    provider.update { $0.failPut = nil }
    let outcome = try await setup.commit(pending, confirming: confirmation)

    #expect(outcome.recipientID == recipientID && outcome.isComplete)
    #expect(try await Self.listed(recipientID, in: provider) == [RuntimeFixture.keyID(1), RuntimeFixture.keyID(2)])
  }

  @Test("should seal a key that joins the ring while the setup is running")
  func keyJoinsDuringSetup() async throws {
    let provider = HookedProvider()
    let device = try Self.device(provider)
    let arriving = KeyFixture.key(2)
    let name = KeyRing.itemName(vault: device.vault, key: arriving.id)
    let ringStore = device.ringStore
    provider.update { $0.beforePut = { _ in _ = try? ringStore.insertData(arriving.rawBytes, forKey: name) } }

    let (_, outcome) = try await KeyFixture.commit(device.setup())

    #expect(outcome.sealed == [RuntimeFixture.keyID(1), RuntimeFixture.keyID(2)] && outcome.isComplete)
    #expect(try await Self.listed(outcome.recipientID, in: provider) == outcome.sealed)
  }

  @Test("should retire the previous phrase, delete its copies by name and refuse it afterwards")
  func newPhraseRetiresOld() async throws {
    let provider = InMemoryStorageProvider()
    let key = KeyFixture.key(1)
    let device = try Self.device(provider, keys: [key])
    try await KeyFixture.putHeldFile(sealedWith: key, in: provider)
    let (oldPhrase, first) = try await KeyFixture.commit(device.setup(clock: 1_000))
    let (newPhrase, second) = try await KeyFixture.commit(device.setup(clock: 2_000))

    #expect(second.retiredRecipients == [first.recipientID] && second.isComplete)
    #expect(try await KeyFixture.copies(of: first.recipientID, in: provider).isEmpty)
    #expect(try await Self.listed(second.recipientID, in: provider) == [key.id])
    #expect(try await device.setup().status() == .active(recipientID: second.recipientID, createdMillis: 2_000))

    let fresh = try KeyDevice(InMemoryKeychain().device("fresh"), vault: KeyFixture.vault, provider: provider)
    await #expect(throws: RecoveryError.noRecoveryCopies) { try await fresh.recovery.recover(oldPhrase) }
    #expect(fresh.ring.keyIDs.isEmpty)
    #expect(try await fresh.recovery.recover(newPhrase).added == [key.id])
  }

  @Test("should report an unfinished setup when the old copies cannot be deleted, and finish it on reconcile")
  func failedDeletionFinishesOnReconcile() async throws {
    let provider = HookedProvider()
    let device = try Self.device(provider)
    let (_, first) = try await KeyFixture.commit(device.setup(clock: 1_000))
    provider.update { $0.failDeletes = true }

    let (_, second) = try await KeyFixture.commit(device.setup(clock: 2_000))

    #expect(!second.isComplete && second.retiredRecipients == [first.recipientID])
    #expect(try await device.setup().status() == .active(recipientID: second.recipientID, createdMillis: 2_000))
    #expect(try await KeyFixture.copies(of: first.recipientID, in: provider).count == 1)

    provider.update { $0.failDeletes = false }
    let reconciled = try await device.setup().reconcile()

    #expect(reconciled.deleted == [VaultPath.sealedKey(recipient: first.recipientID, key: RuntimeFixture.keyID(1))] && reconciled.sealed.isEmpty)
    #expect(try await KeyFixture.copies(of: first.recipientID, in: provider).isEmpty)
    #expect(try await device.setup().reconcile() == .unchanged)
  }

  @Test("should seal a key that joins the ring after the setup when reconciled, and only once")
  func reconcileSealsLaterKeys() async throws {
    let provider = InMemoryStorageProvider()
    let device = try Self.device(provider)
    let setup = device.setup()
    #expect(try await setup.reconcile() == .unchanged)
    let (_, outcome) = try await KeyFixture.commit(setup)
    let later = KeyFixture.key(2)
    _ = try device.ringStore.insertData(later.rawBytes, forKey: KeyRing.itemName(vault: device.vault, key: later.id))

    let reconciled = try await setup.reconcile()

    #expect(reconciled.sealed == [later.id] && reconciled.retiredRecipients.isEmpty && reconciled.deleted.isEmpty)
    #expect(try await Self.listed(outcome.recipientID, in: provider) == [RuntimeFixture.keyID(1), later.id])
    #expect(try await setup.reconcile() == .unchanged)
  }

  @Test("should retire a phrase that a concurrent setup on another device superseded and delete its copies")
  func concurrentSetupsSettleOnOne() async throws {
    let provider = InMemoryStorageProvider()
    let key = KeyFixture.key(1)
    let device = try Self.device(provider, keys: [key])
    try await KeyFixture.putHeldFile(sealedWith: key, in: provider)
    let (minePhrase, mine) = try await KeyFixture.commit(device.setup(clock: 1_000))
    let theirs = RecoveryKey(secret: .generate(), vault: device.vault).recipient
    _ = try await provider.put(
      VaultPath.sealedKey(recipient: theirs.id, key: key.id), data: try SealedRingKey.seal(key, to: theirs, vault: device.vault), condition: .overwrite)
    try await device.store.write { transaction in try ReplicaDirectory.setRecovery(theirs, createdMillis: 1_500, in: &transaction) }
    #expect(try await device.setup().status() == .active(recipientID: theirs.id, createdMillis: 1_500))

    let reconciled = try await device.setup().reconcile()

    #expect(reconciled.sealed == [key.id] && reconciled.retiredRecipients == [mine.recipientID])
    #expect(reconciled.deleted == [VaultPath.sealedKey(recipient: mine.recipientID, key: key.id)])
    #expect(try await KeyFixture.copies(of: mine.recipientID, in: provider).isEmpty)
    let directory = try await device.store.read { try ReplicaDirectory.read(in: $0) }
    #expect(directory.recoveries.map(\.state) == [.retired, .active] && directory.recovery == theirs)
    let fresh = try KeyDevice(InMemoryKeychain().device("fresh"), vault: KeyFixture.vault, provider: provider)
    await #expect(throws: RecoveryError.noRecoveryCopies) { try await fresh.recovery.recover(minePhrase) }
  }

  @Test("should delete the replaced phrase's copies by name while the listing does not show them")
  func deletesWithoutListing() async throws {
    let provider = HookedProvider()
    let device = try Self.device(provider)
    let (_, first) = try await KeyFixture.commit(device.setup(clock: 1_000))
    provider.update { $0.hiddenFromListing = "keys/" }

    let (_, second) = try await KeyFixture.commit(device.setup(clock: 2_000))

    #expect(second.isComplete)
    provider.update { $0.hiddenFromListing = nil }
    #expect(try await KeyFixture.copies(of: first.recipientID, in: provider).isEmpty)
    #expect(try await Self.listed(second.recipientID, in: provider) == [RuntimeFixture.keyID(1)])
  }

  @Test("should leave copies under a recipient the vault never recorded and a retired recipient's copy of a key the ring does not hold")
  func reconcileDeletesOnlyRecordedNames() async throws {
    let provider = InMemoryStorageProvider()
    let key = KeyFixture.key(1)
    let device = try Self.device(provider, keys: [key])
    let (oldPhrase, first) = try await KeyFixture.commit(device.setup(clock: 1_000))
    let oldRecipient = RecoveryKey(secret: oldPhrase.secret, vault: device.vault).recipient
    let foreignKey = KeyFixture.key(9)
    let foreignCopy = VaultPath.sealedKey(recipient: first.recipientID, key: foreignKey.id)
    _ = try await provider.put(foreignCopy, data: try SealedRingKey.seal(foreignKey, to: oldRecipient, vault: device.vault), condition: .overwrite)
    let stranger = RecoveryKey(secret: .generate(), vault: device.vault).recipient
    let planted = VaultPath.sealedKey(recipient: stranger.id, key: key.id)
    _ = try await provider.put(planted, data: try SealedRingKey.seal(key, to: stranger, vault: device.vault), condition: .overwrite)
    _ = try await KeyFixture.commit(device.setup(clock: 2_000))

    _ = try await device.setup().reconcile()

    let remaining = Set(try await provider.listAll(prefix: "keys/").map(\.key))
    #expect(remaining.contains(planted) && remaining.contains(foreignCopy))
    #expect(!remaining.contains(VaultPath.sealedKey(recipient: first.recipientID, key: key.id)))
  }

  @Test("should run two commits on one setup one after the other, so the later call's phrase is the one that stays")
  func concurrentCommitsOnOneSetup() async throws {
    let provider = HookedProvider()
    let device = try Self.device(provider)
    let setup = device.setup()
    let (early, late) = (setup.begin(), setup.begin())
    let earlyID = KeyFixture.recipientID(try KeyFixture.phrase(of: early))
    let lateID = KeyFixture.recipientID(try KeyFixture.phrase(of: late))
    let (earlyConfirmation, lateConfirmation) = (try KeyFixture.confirmation(for: early), try KeyFixture.confirmation(for: late))
    let earlyPut = Flag(false)
    let store = device.store
    provider.update { hooks in
      hooks.beforePut = { key in
        guard key.rawValue.hasPrefix("keys/\(earlyID)/") else { return }
        earlyPut.set(true)
        for _ in 0..<50 {
          let recorded = try? await store.read { try ReplicaDirectory.read(in: $0).recoveries.contains { $0.recipientID == lateID } }
          if recorded == true { return }
          try? await Task.sleep(for: .milliseconds(10))
        }
      }
    }

    async let first = setup.commit(early, confirming: earlyConfirmation)
    while !earlyPut.isSet { await Task.yield() }
    async let second = setup.commit(late, confirming: lateConfirmation)
    _ = try await (first, second)

    let directory = try await store.read { try ReplicaDirectory.read(in: $0) }
    #expect(directory.recoveries.filter { $0.state == .active }.map(\.recipientID) == [lateID])
    #expect(directory.recovery?.id == lateID)
    #expect(try await KeyFixture.copies(of: earlyID, in: provider).isEmpty)
  }

  @Test("should not put back a replaced phrase's copies when a device that has not heard of the new phrase reconciles")
  func staleDeviceDoesNotRestoreOldCopies() async throws {
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let key = KeyFixture.key(1)
    let phone = try KeyDevice(keychain.device("phone"), vault: KeyFixture.vault, provider: provider)
    let tablet = try KeyDevice(keychain.device("tablet"), vault: KeyFixture.vault, provider: provider)
    for device in [phone, tablet] { try device.ring.add(key) }
    let (oldPhrase, old) = try await KeyFixture.commit(phone.setup(clock: 1_000))
    let oldRecipient = RecoveryKey(secret: oldPhrase.secret, vault: KeyFixture.vault).recipient
    try await tablet.store.write { transaction in try ReplicaDirectory.setRecovery(oldRecipient, createdMillis: 1_000, in: &transaction) }
    let tabletSetup = tablet.setup()
    _ = try await tabletSetup.reconcile()

    _ = try await KeyFixture.commit(phone.setup(clock: 2_000))
    #expect(try await KeyFixture.copies(of: old.recipientID, in: provider).isEmpty)
    let stale = try await tabletSetup.reconcile()

    #expect(stale.sealed.isEmpty)
    #expect(try await KeyFixture.copies(of: old.recipientID, in: provider).isEmpty)
    #expect(try await tabletSetup.status() == .active(recipientID: old.recipientID, createdMillis: 1_000))
  }

  @Test("should refuse to set up recovery without a ring key or while the keychain is locked, keeping the phrase open")
  func refusesWithoutKeys() async throws {
    let provider = InMemoryStorageProvider()
    let empty = try Self.device(provider, keys: [])
    let pending = empty.setup().begin()
    await #expect(throws: RecoveryError.noRingKey) { try await empty.setup().commit(pending, confirming: try KeyFixture.confirmation(for: pending)) }

    let locked = try KeyDevice(InMemoryKeychain().device("locked"), vault: KeyFixture.vault, provider: provider, ringStore: LockedSecureStore())
    await #expect(throws: RecoveryError.deviceLocked) { try await locked.setup().commit(pending, confirming: try KeyFixture.confirmation(for: pending)) }
    await #expect(throws: RecoveryError.deviceLocked) { try await locked.setup().reconcile() }

    #expect(!pending.isRecorded)
    #expect(try await provider.listAll(prefix: "").isEmpty)
  }

  @Test("should never show the phrase in descriptions, dumps or errors")
  func redacts() async throws {
    let device = try Self.device()
    let setup = device.setup()
    let pending = setup.begin()
    let phrase = try KeyFixture.phrase(of: pending)
    var dumped = ""
    dump(pending, to: &dumped)
    var dumpedSetup = ""
    dump(setup, to: &dumpedSetup)
    let error = RecoveryError.confirmationMismatch(positions: pending.confirmationPositions)
    let hex = phrase.secret.rawBytes.map { String(format: "%02x", $0) }.joined()
    let texts = [String(describing: pending), String(reflecting: pending), dumped, dumpedSetup, error.errorDescription ?? "", String(describing: error)]

    for text in texts {
      #expect(!text.contains(hex))
      for pair in zip(phrase.words, phrase.words.dropFirst()) { #expect(!text.lowercased().contains("\(pair.0) \(pair.1)")) }
    }
    #expect(String(describing: pending) == "PendingRecoveryPhrase(redacted)")
  }
}
