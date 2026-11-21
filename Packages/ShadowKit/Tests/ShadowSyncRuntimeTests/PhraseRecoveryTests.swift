import Foundation
import ShadowCore
import ShadowKeychain
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import Testing

@Suite("PhraseRecovery", TestTimeLimit.quick)
struct PhraseRecoveryTests {
  private static let phrase = RecoveryPhrase(secret: .generate())

  private static func fresh(_ provider: any StorageProvider, vault: VaultID = KeyFixture.vault) throws -> KeyDevice {
    try KeyDevice(InMemoryKeychain().device("fresh"), vault: vault, provider: provider)
  }

  /// Puts a genuine copy of `key` sealed to `phrase` for `vault` at `path`, by default the copy's own name.
  private static func putCopy(
    of key: VaultKey, phrase: RecoveryPhrase = phrase, vault: VaultID = KeyFixture.vault, at path: ObjectKey? = nil, in provider: any StorageProvider
  ) async throws {
    let recipient = RecoveryKey(secret: phrase.secret, vault: vault).recipient
    let name = path ?? VaultPath.sealedKey(recipient: recipient.id, key: key.id)
    _ = try await provider.put(name, data: try SealedRingKey.seal(key, to: recipient, vault: vault), condition: .overwrite)
  }

  /// A copy made by someone who knows the recipient's public key but not the sealing key only the phrase and the sealed vault state hold.
  private static func putForgery(of key: VaultKey, in provider: any StorageProvider) async throws {
    let genuine = RecoveryKey(secret: phrase.secret, vault: KeyFixture.vault).recipient
    let forger = try #require(RecoveryRecipient(publicKey: genuine.publicKey, sealingKey: Data(repeating: 7, count: 32)))
    _ = try await provider.put(
      VaultPath.sealedKey(recipient: genuine.id, key: key.id), data: try SealedRingKey.seal(key, to: forger, vault: KeyFixture.vault), condition: .overwrite)
  }

  @Test("should refuse a forged copy, also one with an old-looking key id, and keep the genuine one")
  func forgedCopy() async throws {
    let provider = InMemoryStorageProvider()
    let genuine = KeyFixture.key(5)
    let forged = KeyFixture.key(1)
    try await KeyFixture.putHeldFile(sealedWith: forged, in: provider)
    try await Self.putForgery(of: forged, in: provider)

    let device = try Self.fresh(provider)
    await #expect(throws: RecoveryError.recoveryCopiesRefused) { try await device.recovery.recover(Self.phrase) }
    #expect(device.ring.keyIDs.isEmpty)

    try await KeyFixture.putHeldFile(sealedWith: genuine, in: provider)
    try await Self.putCopy(of: genuine, in: provider)
    let imported = try await device.recovery.recover(Self.phrase)

    #expect(imported.added == [genuine.id] && imported.unconfirmed.isEmpty)
    #expect(device.ring.keyIDs == [genuine.id] && device.ring.writingKey()?.id == genuine.id)
  }

  @Test("should refuse a genuine copy stored under another key's name")
  func misplacedCopy() async throws {
    let provider = InMemoryStorageProvider()
    let key = KeyFixture.key(5)
    try await KeyFixture.putHeldFile(sealedWith: key, in: provider)
    let recipientID = KeyFixture.recipientID(Self.phrase)
    try await Self.putCopy(of: key, at: VaultPath.sealedKey(recipient: recipientID, key: RuntimeFixture.keyID(1)), in: provider)

    let device = try Self.fresh(provider)
    await #expect(throws: RecoveryError.recoveryCopiesRefused) { try await device.recovery.recover(Self.phrase) }
    #expect(device.ring.keyIDs.isEmpty)
  }

  @Test("should find nothing with the wrong phrase or for another vault, and refuse another vault's copy moved here")
  func wrongPhraseOrVault() async throws {
    let provider = InMemoryStorageProvider()
    let key = KeyFixture.key(5)
    try await KeyFixture.putHeldFile(sealedWith: key, in: provider)
    try await Self.putCopy(of: key, in: provider)

    await #expect(throws: RecoveryError.noRecoveryCopies) { try await Self.fresh(provider).recovery.recover(RecoveryPhrase(secret: .generate())) }
    await #expect(throws: RecoveryError.noRecoveryCopies) { try await Self.fresh(provider, vault: KeyFixture.otherVault).recovery.recover(Self.phrase) }

    let otherVaultPath = VaultPath.sealedKey(recipient: KeyFixture.recipientID(Self.phrase, vault: KeyFixture.otherVault), key: key.id)
    try await Self.putCopy(of: key, at: otherVaultPath, in: provider)
    let other = try Self.fresh(provider, vault: KeyFixture.otherVault)
    await #expect(throws: RecoveryError.recoveryCopiesRefused) { try await other.recovery.recover(Self.phrase) }
    #expect(other.ring.keyIDs.isEmpty)
  }

  @Test("should never add a key that opens no file the vault holds, and add it once such a file exists")
  func keyThatOpensNothing() async throws {
    let provider = InMemoryStorageProvider()
    let key = KeyFixture.key(5)
    try await Self.putCopy(of: key, in: provider)
    try await KeyFixture.putHeldFile(sealedWith: KeyFixture.key(5), in: provider)
    try await KeyFixture.putHeldFile(sealedWith: key, vault: KeyFixture.otherVault, in: provider)
    let device = try Self.fresh(provider)

    await #expect(throws: RecoveryError.keysUnconfirmed([key.id])) { try await device.recovery.recover(Self.phrase) }
    #expect(device.ring.keyIDs.isEmpty)
    #expect(try RuntimeFixture.ringKeys(device.keychain, vault: KeyFixture.vault).isEmpty)

    try await KeyFixture.putHeldFile(sealedWith: key, in: provider)
    #expect(try await device.recovery.recover(Self.phrase).added == [key.id])
  }

  @Test("should add the confirmed keys and report the rest as unconfirmed, held or conflicting")
  func mixedOutcome() async throws {
    let provider = InMemoryStorageProvider()
    let (confirmed, unconfirmed, held, conflicting) = (KeyFixture.key(1), KeyFixture.key(2), KeyFixture.key(3), KeyFixture.key(4))
    for key in [confirmed, unconfirmed, held, conflicting] { try await Self.putCopy(of: key, in: provider) }
    for key in [confirmed, held, conflicting] { try await KeyFixture.putHeldFile(sealedWith: key, in: provider) }
    let device = try Self.fresh(provider)
    try device.ring.add(held)
    _ = try device.ringStore.insertData(Data(repeating: 9, count: 32), forKey: KeyRing.itemName(vault: device.vault, key: conflicting.id))

    let imported = try await device.recovery.recover(Self.phrase)

    #expect(imported.added == [confirmed.id] && imported.alreadyHeld == [held.id])
    #expect(imported.unconfirmed == [unconfirmed.id] && imported.conflicting == [conflicting.id])
    #expect(device.ring.keyIDs == [confirmed.id, held.id, conflicting.id])
    #expect(device.ring.key(conflicting.id)?.rawBytes == Data(repeating: 9, count: 32))
  }

  @Test("should find copies the listing has not shown yet through the keys the vault's manifests name")
  func staleListing() async throws {
    let provider = HookedProvider()
    let key = KeyFixture.key(5)
    try await KeyFixture.putHeldFile(sealedWith: key, in: provider)
    try await Self.putCopy(of: key, in: provider)
    provider.update { $0.hiddenFromListing = "keys/" }

    #expect(try await Self.fresh(provider).recovery.recover(Self.phrase).added == [key.id])
  }

  @Test("should report a locked keychain")
  func lockedKeychain() async throws {
    let provider = InMemoryStorageProvider()
    let device = try KeyDevice(InMemoryKeychain().device("locked"), vault: KeyFixture.vault, provider: provider, ringStore: LockedSecureStore())

    await #expect(throws: RecoveryError.deviceLocked) { try await device.recovery.recover(Self.phrase) }
  }
}
