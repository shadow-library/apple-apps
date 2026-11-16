import Foundation
import ShadowCore
import ShadowKeychain
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

private final class RecordingStore: SecureStore {
  enum Call: Hashable, Sendable {
    case data
    case setData
    case insertData
    case removeValue
    case allKeys
  }

  let base: any SecureStore
  private let recorded = Mutex<[Call]>([])

  init(_ base: any SecureStore) {
    self.base = base
  }

  var calls: [Call] { recorded.withLock { $0 } }

  func data(forKey key: String) throws(SecureStoreError) -> Data? {
    recorded.withLock { $0.append(.data) }
    return try base.data(forKey: key)
  }

  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) {
    recorded.withLock { $0.append(.setData) }
    try base.setData(data, forKey: key)
  }

  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool {
    recorded.withLock { $0.append(.insertData) }
    return try base.insertData(data, forKey: key)
  }

  func removeValue(forKey key: String) throws(SecureStoreError) {
    recorded.withLock { $0.append(.removeValue) }
    try base.removeValue(forKey: key)
  }

  func allKeys() throws(SecureStoreError) -> [String] {
    recorded.withLock { $0.append(.allKeys) }
    return try base.allKeys()
  }
}

private struct FailingStore: SecureStore {
  let leak: String

  func data(forKey key: String) throws(SecureStoreError) -> Data? { throw .decoding(leak) }
  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) { throw .encoding(lowercaseHex(data)) }
  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool { throw .encoding(lowercaseHex(data)) }
  func removeValue(forKey key: String) throws(SecureStoreError) { throw .unexpectedStatus(-25_300) }
  func allKeys() throws(SecureStoreError) -> [String] { throw .unexpectedStatus(-25_308) }
}

private struct ListingStore: SecureStore {
  let base: InMemorySecureStore
  let names: [String]

  func data(forKey key: String) throws(SecureStoreError) -> Data? { try base.data(forKey: key) }
  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) { try base.setData(data, forKey: key) }
  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool { try base.insertData(data, forKey: key) }
  func removeValue(forKey key: String) throws(SecureStoreError) { try base.removeValue(forKey: key) }
  func allKeys() throws(SecureStoreError) -> [String] { names }
}

@Suite("KeyRing")
struct KeyRingTests {
  private static func vault(_ raw: String = "vault-one") throws -> VaultID {
    try #require(VaultID(raw))
  }

  private static func keyID(_ text: String) throws -> KeyID {
    try #require(KeyID(text))
  }

  private static func key(_ text: String, byte: UInt8) throws -> VaultKey {
    try #require(VaultKey(id: keyID(text), rawBytes: Data(repeating: byte, count: 32)))
  }

  @Test("should show a key created on one device on another only after delivery, and report it once")
  func shouldDeliverAcrossDevices() throws {
    let keychain = InMemoryKeychain()
    let vault = try Self.vault()
    let ringA = KeyRing(vault: vault, store: keychain.device("a").store(service: "shadow", scope: .synced))
    let ringB = KeyRing(vault: vault, store: keychain.device("b").store(service: "shadow", scope: .synced))
    let created = try ringA.createKey()
    #expect(ringA.keyIDs == [created.id])
    #expect(try ringB.refresh().isEmpty)
    #expect(ringB.key(created.id) == nil)
    keychain.deliver()
    #expect(try ringB.refresh() == [created.id])
    #expect(try ringB.refresh().isEmpty)
    #expect(ringB.key(created.id)?.rawBytes == created.rawBytes)
    #expect(try ringA.refresh().isEmpty)
  }

  @Test("should call only insertData, data and allKeys on the store")
  func shouldUseOnlyNonDestructiveCalls() throws {
    let vault = try Self.vault()
    let base = InMemorySecureStore([
      KeyRing.itemName(vault: vault, key: try Self.keyID("00000000-0000-7000-8000-000000000001")): Data(repeating: 1, count: 32),
      "vault-key/\(vault)/garbage": Data([1]),
      KeyRing.itemName(vault: vault, key: try Self.keyID("00000000-0000-7000-8000-000000000002")): Data(repeating: 2, count: 31),
    ])
    let store = RecordingStore(base)
    let ring = KeyRing(vault: vault, store: store)
    try ring.refresh()
    let created = try ring.createKey()
    try ring.add(created)
    try ring.add(try Self.key("00000000-0000-7000-8000-000000000003", byte: 3))
    #expect(throws: KeyRingError.conflictingKey(try Self.keyID("00000000-0000-7000-8000-000000000001"))) {
      try ring.add(try Self.key("00000000-0000-7000-8000-000000000001", byte: 9))
    }
    #expect(throws: KeyRingError.conflictingKey(try Self.keyID("00000000-0000-7000-8000-000000000002"))) {
      try ring.add(try Self.key("00000000-0000-7000-8000-000000000002", byte: 2))
    }
    try ring.refresh()
    _ = ring.writingKey()
    _ = ring.writingKey(floor: created.id)
    _ = ring.key(created.id)
    _ = ring.unreadableItems
    #expect(!store.calls.isEmpty)
    #expect(Set(store.calls).isSubset(of: [.insertData, .data, .allKeys]))
  }

  @Test("should never replace an item: a conflicting add throws and leaves the stored bytes unchanged")
  func shouldBeWriteOnce() throws {
    let vault = try Self.vault()
    let store = InMemorySecureStore()
    let ring = KeyRing(vault: vault, store: store)
    let original = try Self.key("00000000-0000-7000-8000-000000000001", byte: 0x11)
    let impostor = try Self.key("00000000-0000-7000-8000-000000000001", byte: 0x22)
    try ring.add(original)
    #expect(throws: KeyRingError.conflictingKey(original.id)) { try ring.add(impostor) }
    #expect(try store.data(forKey: KeyRing.itemName(vault: vault, key: original.id)) == original.rawBytes)
    #expect(ring.key(original.id)?.rawBytes == original.rawBytes)

    let fresh = KeyRing(vault: vault, store: store)
    #expect(throws: KeyRingError.conflictingKey(original.id)) { try fresh.add(impostor) }
    #expect(try store.data(forKey: KeyRing.itemName(vault: vault, key: original.id)) == original.rawBytes)
    #expect(fresh.key(original.id) == nil)
  }

  @Test("should refuse a key whose cached bytes differ even after the item has gone, without writing it")
  func shouldCheckCacheBeforeWriting() throws {
    let vault = try Self.vault()
    let store = InMemorySecureStore()
    let ring = KeyRing(vault: vault, store: store)
    let original = try Self.key("00000000-0000-7000-8000-000000000001", byte: 0x11)
    try ring.add(original)
    try store.removeValue(forKey: KeyRing.itemName(vault: vault, key: original.id))
    #expect(throws: KeyRingError.conflictingKey(original.id)) { try ring.add(try Self.key("00000000-0000-7000-8000-000000000001", byte: 0x22)) }
    #expect(try store.data(forKey: KeyRing.itemName(vault: vault, key: original.id)) == nil)
  }

  @Test("should accept the same key twice")
  func shouldAddSameKeyTwice() throws {
    let vault = try Self.vault()
    let store = InMemorySecureStore()
    let key = try Self.key("00000000-0000-7000-8000-000000000001", byte: 0x11)
    try KeyRing(vault: vault, store: store).add(key)
    let ring = KeyRing(vault: vault, store: store)
    try ring.add(key)
    try ring.add(key)
    #expect(ring.keyIDs == [key.id])
    #expect(try ring.refresh().isEmpty)
  }

  @Test("should throw conflictingKey when createKey draws an id that already holds other bytes")
  func shouldRefuseCreateOverExistingItem() throws {
    let vault = try Self.vault()
    let id = try Self.keyID("00000000-0000-7000-8000-000000000001")
    let store = InMemorySecureStore([KeyRing.itemName(vault: vault, key: id): Data(repeating: 7, count: 32)])
    let ring = KeyRing(vault: vault, store: store) { id }
    #expect(throws: KeyRingError.conflictingKey(id)) { try ring.createKey() }
    #expect(try store.data(forKey: KeyRing.itemName(vault: vault, key: id)) == Data(repeating: 7, count: 32))
  }

  @Test("should write with the oldest held key at or above the floor")
  func shouldChooseOldestKey() throws {
    let ring = KeyRing(vault: try Self.vault(), store: InMemorySecureStore())
    #expect(ring.writingKey() == nil)
    let old = try Self.key("01930000-0000-7000-8000-000000000000", byte: 1)
    let middle = try Self.key("01940000-0000-7000-8000-000000000000", byte: 2)
    let new = try Self.key("01950000-0000-7000-8000-000000000000", byte: 3)
    for key in [middle, new, old] { try ring.add(key) }
    #expect(ring.keyIDs == [old.id, middle.id, new.id])
    #expect(ring.writingKey()?.id == old.id)
    #expect(ring.writingKey(floor: old.id)?.id == old.id)
    #expect(ring.writingKey(floor: try Self.keyID("01930000-0000-7000-8000-000000000001"))?.id == middle.id)
    #expect(ring.writingKey(floor: middle.id)?.id == middle.id)
    #expect(ring.writingKey(floor: new.id)?.id == new.id)
    #expect(ring.writingKey(floor: try Self.keyID("01960000-0000-7000-8000-000000000000")) == nil)
    #expect(ring.writingKey()?.rawBytes == old.rawBytes)
  }

  @Test("should settle two devices on the older of two keys created at the same time")
  func shouldSettleOnOldestAcrossDevices() throws {
    let keychain = InMemoryKeychain()
    let vault = try Self.vault()
    let ringA = KeyRing(vault: vault, store: keychain.device("a").store(service: "shadow", scope: .synced)) {
      KeyID(UUID(uuidString: "01930000-0000-7000-8000-000000000000") ?? UUID())
    }
    let ringB = KeyRing(vault: vault, store: keychain.device("b").store(service: "shadow", scope: .synced)) {
      KeyID(UUID(uuidString: "01940000-0000-7000-8000-000000000000") ?? UUID())
    }
    let keyA = try ringA.createKey()
    _ = try ringB.createKey()
    keychain.deliver()
    try ringA.refresh()
    try ringB.refresh()
    #expect(ringA.writingKey()?.id == keyA.id)
    #expect(ringB.writingKey()?.id == keyA.id)
  }

  @Test("should ignore keys of other vaults, including a vault whose id extends this one")
  func shouldIgnoreOtherVaults() throws {
    let vault = try Self.vault("a")
    let other = try Self.vault("a-b")
    let store = InMemorySecureStore()
    let mine = try Self.key("00000000-0000-7000-8000-000000000001", byte: 1)
    try KeyRing(vault: other, store: store).add(try Self.key("00000000-0000-7000-8000-000000000002", byte: 2))
    try KeyRing(vault: try Self.vault("b"), store: store).add(try Self.key("00000000-0000-7000-8000-000000000003", byte: 3))
    try store.setData(Data(repeating: 4, count: 32), forKey: "vault-key/a")
    try store.setData(Data(repeating: 4, count: 32), forKey: "vault-keya/00000000-0000-7000-8000-000000000004")
    try store.setData(Data(repeating: 4, count: 32), forKey: "anthropic-api-key")
    try KeyRing(vault: vault, store: store).add(mine)
    let ring = KeyRing(vault: vault, store: store)
    #expect(try ring.refresh() == [mine.id])
    #expect(ring.keyIDs == [mine.id])
    #expect(ring.unreadableItems.isEmpty)
  }

  @Test("should report unreadable items and leave them in place")
  func shouldReportUnreadableItems() throws {
    let vault = try Self.vault()
    let prefix = "vault-key/\(vault)/"
    let items: [String: Data] = [
      prefix + "garbage": Data(repeating: 1, count: 32),
      prefix + "00000000-0000-7000-8000-00000000000A": Data(repeating: 2, count: 32),
      prefix + "00000000-0000-7000-8000-000000000001/extra": Data(repeating: 3, count: 32),
      prefix: Data(repeating: 4, count: 32),
      prefix + "00000000-0000-7000-8000-000000000002": Data(repeating: 5, count: 31),
      prefix + "00000000-0000-7000-8000-000000000003": Data(repeating: 6, count: 33),
      prefix + "00000000-0000-7000-8000-000000000004": Data(),
    ]
    let valid = try Self.key("00000000-0000-7000-8000-000000000005", byte: 7)
    let store = InMemorySecureStore(items.merging([KeyRing.itemName(vault: vault, key: valid.id): valid.rawBytes]) { $1 })
    let ring = KeyRing(vault: vault, store: store)
    #expect(try ring.refresh() == [valid.id])
    #expect(ring.unreadableItems == items.keys.sorted())
    _ = try ring.createKey()
    try ring.refresh()
    #expect(ring.unreadableItems == items.keys.sorted())
    for (name, data) in items { #expect(try store.data(forKey: name) == data) }
  }

  @Test("should keep reporting an unreadable item seen by any refresh, whatever order listings arrive in")
  func shouldAccumulateUnreadableItems() throws {
    let vault = try Self.vault()
    let first = "vault-key/\(vault)/first-bad"
    let second = "vault-key/\(vault)/second-bad"
    let store = InMemorySecureStore([first: Data([1])])
    let ring = KeyRing(vault: vault, store: store)
    try ring.refresh()
    #expect(ring.unreadableItems == [first])
    try store.removeValue(forKey: first)
    try store.setData(Data([2]), forKey: second)
    try ring.refresh()
    #expect(ring.unreadableItems == [first, second])
    let stale = KeyRing(vault: vault, store: ListingStore(base: store, names: [first]))
    try stale.refresh()
    #expect(stale.unreadableItems == [first])
  }

  @Test("should skip an item that disappears between listing and reading")
  func shouldSkipVanishedItem() throws {
    let vault = try Self.vault()
    let id = try Self.keyID("00000000-0000-7000-8000-000000000001")
    let ring = KeyRing(vault: vault, store: ListingStore(base: InMemorySecureStore(), names: [KeyRing.itemName(vault: vault, key: id)]))
    #expect(try ring.refresh().isEmpty)
    #expect(ring.keyIDs.isEmpty)
    #expect(ring.unreadableItems.isEmpty)
  }

  @Test("should turn store errors into KeyRingError.store without key material")
  func shouldMapStoreErrors() throws {
    let vault = try Self.vault()
    let key = try Self.key("00000000-0000-7000-8000-000000000001", byte: 0xAB)
    let leak = lowercaseHex(key.rawBytes)
    let failing = KeyRing(vault: vault, store: FailingStore(leak: leak))
    var errors: [KeyRingError] = []
    let operations: [() throws(KeyRingError) -> Void] = [
      { () throws(KeyRingError) in try failing.refresh() },
      { () throws(KeyRingError) in _ = try failing.createKey() },
      { () throws(KeyRingError) in try failing.add(key) },
    ]
    for operation in operations {
      do {
        try operation()
        Issue.record("expected a store error")
      } catch {
        errors.append(error)
      }
    }
    let readFailing = KeyRing(vault: vault, store: FailingReadStore(names: [KeyRing.itemName(vault: vault, key: key.id)], leak: leak))
    #expect(throws: KeyRingError.store("secure_store.decoding")) { try readFailing.refresh() }
    #expect(errors == [.store("secure_store.unexpected_status -25308"), .store("secure_store.encoding"), .store("secure_store.encoding")])
    for error in errors {
      for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
        #expect(!text.contains(leak))
        #expect(!text.lowercased().contains("abab"))
      }
    }
  }

  @Test("should keep a cached key after its item disappears")
  func shouldKeepCachedKey() throws {
    let vault = try Self.vault()
    let store = InMemorySecureStore()
    let key = try Self.key("00000000-0000-7000-8000-000000000001", byte: 1)
    try KeyRing(vault: vault, store: store).add(key)
    let ring = KeyRing(vault: vault, store: store)
    #expect(try ring.refresh() == [key.id])
    try store.removeValue(forKey: KeyRing.itemName(vault: vault, key: key.id))
    #expect(try ring.refresh().isEmpty)
    #expect(ring.key(key.id)?.rawBytes == key.rawBytes)
    #expect(ring.writingKey()?.id == key.id)
  }

  @Test("should open a vault file with the ring as the key lookup")
  func shouldServeVaultFileOpen() throws {
    let vault = try Self.vault()
    let ring = KeyRing(vault: vault, store: InMemorySecureStore())
    let key = try ring.createKey()
    let sealed = try VaultFile.seal(Data("hello".utf8), path: "a.json", vault: vault, key: key)
    #expect(try VaultFile.open(sealed, path: "a.json", vault: vault, keys: ring.key) == Data("hello".utf8))
  }

  @Test("should lose no key under 100 concurrent createKey, refresh and add calls")
  func shouldBeThreadSafe() throws {
    let keychain = InMemoryKeychain()
    let vault = try Self.vault()
    let peer = KeyRing(vault: vault, store: keychain.device("peer").store(service: "shadow", scope: .synced))
    let external = (0..<20).map { _ in VaultKey.generate(id: KeyID(UUID.v7())) }
    let peerKeys = try (0..<10).map { _ in try peer.createKey() }
    let ring = KeyRing(vault: vault, store: DelayingStore(base: keychain.device("main").store(service: "shadow", scope: .synced)))
    keychain.deliver()
    let created = Mutex<[KeyID]>([])
    let seen = Mutex<[KeyID]>([])
    let failures = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 100) { index in
      do {
        switch index % 3 {
        case 0:
          let key = try ring.createKey()
          created.withLock { $0.append(key.id) }
        case 1:
          let ids = try ring.refresh()
          seen.withLock { $0.append(contentsOf: ids) }
        default:
          try ring.add(external[index % external.count])
        }
      } catch {
        failures.withLock { $0.append(String(describing: error)) }
      }
    }
    #expect(failures.withLock { $0 }.isEmpty)
    let expected = Set(created.withLock { $0 }).union(external.map(\.id)).union(peerKeys.map(\.id))
    #expect(created.withLock { $0.count } == 34)
    #expect(Set(ring.keyIDs) == expected)
    let reported = seen.withLock { $0 } + Array(try ring.refresh())
    #expect(reported.count == Set(reported).count)
    #expect(Set(peerKeys.map(\.id)).isSubset(of: Set(reported)))
    for key in external { #expect(ring.key(key.id)?.rawBytes == key.rawBytes) }
    let reread = KeyRing(vault: vault, store: keychain.device("main").store(service: "shadow", scope: .synced))
    try reread.refresh()
    #expect(Set(reread.keyIDs) == expected)
  }
}

private struct DelayingStore: SecureStore {
  let base: any SecureStore

  private func pause() { Thread.sleep(forTimeInterval: 0.000_2) }

  func data(forKey key: String) throws(SecureStoreError) -> Data? {
    pause()
    return try base.data(forKey: key)
  }

  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) { try base.setData(data, forKey: key) }

  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool {
    pause()
    return try base.insertData(data, forKey: key)
  }

  func removeValue(forKey key: String) throws(SecureStoreError) { try base.removeValue(forKey: key) }

  func allKeys() throws(SecureStoreError) -> [String] {
    pause()
    return try base.allKeys()
  }
}

private struct FailingReadStore: SecureStore {
  let names: [String]
  let leak: String

  func data(forKey key: String) throws(SecureStoreError) -> Data? { throw .decoding(leak) }
  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) { throw .encoding(leak) }
  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool { throw .encoding(leak) }
  func removeValue(forKey key: String) throws(SecureStoreError) { throw .encoding(leak) }
  func allKeys() throws(SecureStoreError) -> [String] { names }
}
