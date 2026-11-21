import Foundation
import ShadowCore
import ShadowKeychain
import ShadowSync
import Testing

nonisolated struct HostedKeychain {
  let service = "com.shadow.apps.novelforge.tests.\(UUID().uuidString.lowercased())"

  func synced() throws -> KeychainStore {
    try refusingWithoutEntitlement(KeychainStore(service: service, scope: .synced(.afterFirstUnlock)))
  }

  func device() throws -> KeychainStore {
    try refusingWithoutEntitlement(KeychainStore(service: service, scope: .device(.afterFirstUnlockThisDeviceOnly)))
  }

  func cleanUp() {
    for store in [KeychainStore(service: service, scope: .synced(.afterFirstUnlock)), KeychainStore(service: service, scope: .device(.afterFirstUnlockThisDeviceOnly))] {
      for name in (try? store.allKeys()) ?? [] { try? store.removeValue(forKey: name) }
    }
  }

  /// Reads answer "not found" on a build without the entitlement; only a write is refused.
  private func refusingWithoutEntitlement(_ store: KeychainStore) throws -> KeychainStore {
    do {
      _ = try store.insertData(Data(), forKey: "probe")
      try store.removeValue(forKey: "probe")
    } catch {
      guard error.isMissingEntitlement else { throw error }
      try Test.cancel("The host lacks the keychain entitlement (errSecMissingEntitlement, -34018): this build has no signing team, so the real keychain cannot be exercised.")
    }
    return store
  }
}

@Suite("Hosted keychain", TestTimeLimit.standard)
struct HostedKeychainTests {
  @Test func shouldKeepSyncedAndThisDeviceItemsOfOneNameApart() throws {
    let keychain = HostedKeychain()
    defer { keychain.cleanUp() }
    let synced = try keychain.synced()
    let device = try keychain.device()

    try synced.setString("synced value", forKey: "token")
    #expect(try device.string(forKey: "token") == nil)
    try device.setString("device value", forKey: "token")

    #expect(try synced.string(forKey: "token") == "synced value")
    #expect(try device.string(forKey: "token") == "device value")
    try device.removeValue(forKey: "token")
    #expect(try synced.string(forKey: "token") == "synced value")
    #expect(try device.allKeys().isEmpty)
    #expect(try synced.allKeys() == ["token"])
  }

  @Test func shouldInsertAnItemOnceAndLeaveItAloneAfterwards() throws {
    let keychain = HostedKeychain()
    defer { keychain.cleanUp() }
    let store = try keychain.synced()

    #expect(try store.insertString("first", forKey: "once"))
    #expect(try !store.insertString("second", forKey: "once"))
    #expect(try store.string(forKey: "once") == "first")

    try store.setString("replaced", forKey: "once")
    #expect(try store.string(forKey: "once") == "replaced")
  }

  @Test func shouldListTheNamesOfItsOwnScopeAndServiceOnly() throws {
    let keychain = HostedKeychain()
    let other = HostedKeychain()
    defer {
      keychain.cleanUp()
      other.cleanUp()
    }
    let synced = try keychain.synced()
    let device = try keychain.device()
    let elsewhere = try other.synced()

    #expect(try synced.allKeys().isEmpty)
    try synced.setString("b", forKey: "beta")
    try synced.setString("a", forKey: "alpha")
    try device.setString("d", forKey: "delta")
    try elsewhere.setString("e", forKey: "epsilon")

    #expect(try synced.allKeys() == ["alpha", "beta"])
    #expect(try device.allKeys() == ["delta"])
    #expect(try elsewhere.allKeys() == ["epsilon"])
  }

  @Test func shouldReturnNilForAMissingItemAndAcceptRemovingIt() throws {
    let keychain = HostedKeychain()
    defer { keychain.cleanUp() }
    let store = try keychain.device()

    #expect(try store.data(forKey: "absent") == nil)
    try store.removeValue(forKey: "absent")
  }

  @Test func shouldKeepAKeyRingOverTheRealKeychainWriteOnceAcrossInstances() throws {
    let keychain = HostedKeychain()
    defer { keychain.cleanUp() }
    let vault = try #require(VaultID("hosted-vault"))
    let store = try keychain.synced()
    let first = KeyRing(vault: vault, store: store)

    let created = try first.createKey()
    let second = KeyRing(vault: vault, store: store)
    #expect(second.keyIDs.isEmpty)
    #expect(try second.refresh() == [created.id])
    #expect(second.key(created.id)?.hasSameBytes(as: created) == true)

    try second.add(created)
    let impostor = VaultKey.generate(id: created.id)
    #expect(throws: KeyRingError.conflictingKey(created.id)) { try second.add(impostor) }
    #expect(throws: KeyRingError.conflictingKey(created.id)) { try KeyRing(vault: vault, store: store).add(impostor) }
    #expect(try store.data(forKey: KeyRing.itemName(vault: vault, key: created.id)) == created.rawBytes)
  }

  @Test func shouldListOnlyTheKeysOfItsOwnVaultInASharedService() throws {
    let keychain = HostedKeychain()
    defer { keychain.cleanUp() }
    let store = try keychain.synced()
    let mine = try #require(VaultID("hosted-mine"))
    let theirs = try #require(VaultID("hosted-theirs"))
    let ring = KeyRing(vault: mine, store: store)

    let own = try ring.createKey()
    let foreign = try KeyRing(vault: theirs, store: store).createKey()

    #expect(try KeyRing(vault: mine, store: store).refresh() == [own.id])
    #expect(try KeyRing(vault: theirs, store: store).refresh() == [foreign.id])
    #expect(try store.allKeys().count == 2)
  }
}
