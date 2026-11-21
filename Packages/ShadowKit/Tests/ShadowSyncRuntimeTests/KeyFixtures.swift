import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import Synchronization

/// One device of a vault for the key services: its own keychain, ring and store, and the location every device shares.
struct KeyDevice {
  let keychain: InMemoryKeychain.Device
  let ringStore: any SecureStore
  let ring: KeyRing
  let store: VaultStore
  let provider: any StorageProvider

  init(_ keychain: InMemoryKeychain.Device, vault: VaultID, provider: any StorageProvider, ringStore: (any SecureStore)? = nil) throws {
    self.keychain = keychain
    self.ringStore = ringStore ?? keychain.store(service: RuntimeFixture.ringService, scope: .synced)
    ring = KeyRing(vault: vault, store: self.ringStore)
    store = try RuntimeFixture.openStore()
    self.provider = provider
  }

  var vault: VaultID { ring.vault }

  func setup(clock: Int64 = 1_700_000_000_000) -> RecoverySetup {
    RecoverySetup(store: store, provider: provider, ring: ring, wallClock: { Date(timeIntervalSince1970: Double(clock) / 1000) })
  }

  var recovery: PhraseRecovery { PhraseRecovery(provider: provider, ring: ring) }

  func exchange() -> KeyExchangeCoordinator {
    KeyExchangeCoordinator(provider: provider, ring: ring)
  }
}

enum KeyFixture {
  static let vault = RuntimeFixture.vault("vault-keys")
  static let otherVault = RuntimeFixture.vault("vault-other")

  static func key(_ index: Int) -> VaultKey {
    VaultKey.generate(id: RuntimeFixture.keyID(index))
  }

  /// A file the vault holds, sealed with `key` the way every replica seals its manifest.
  @discardableResult
  static func putHeldFile(sealedWith key: VaultKey, vault: VaultID = vault, in provider: any StorageProvider) async throws -> ObjectKey {
    let path = VaultPath.manifest(ReplicaID(UUID.v7()))
    _ = try await provider.put(path, data: try VaultFile.seal(Data("{}".utf8), path: path.rawValue, vault: vault, key: key), condition: .overwrite)
    return path
  }

  static func confirmation(for pending: PendingRecoveryPhrase) throws -> [Int: String] {
    guard let words = pending.phrase?.words else { throw RuntimeFixtureFailure("the phrase was already recorded") }
    return Dictionary(uniqueKeysWithValues: pending.confirmationPositions.map { ($0, words[$0 - 1]) })
  }

  static func commit(_ setup: RecoverySetup) async throws -> (phrase: RecoveryPhrase, outcome: RecoverySetupOutcome) {
    let pending = setup.begin()
    let phrase = try self.phrase(of: pending)
    return (phrase, try await setup.commit(pending, confirming: try confirmation(for: pending)))
  }

  static func phrase(of pending: PendingRecoveryPhrase) throws -> RecoveryPhrase {
    guard let phrase = pending.phrase else { throw RuntimeFixtureFailure("a new pending phrase holds its words") }
    return phrase
  }

  static func copies(of recipientID: String, in provider: any StorageProvider) async throws -> [ObjectKey] {
    try await provider.listAll(prefix: "keys/\(recipientID)/").map(\.key)
  }

  static func recipientID(_ phrase: RecoveryPhrase, vault: VaultID = vault) -> String {
    RecoveryKey(secret: phrase.secret, vault: vault).recipient.id
  }
}

/// Wraps an in-memory location with scripted faults: puts that fail by key, failing deletes, a listing that hides a prefix, and a hook before puts.
final class HookedProvider: StorageProvider {
  struct Hooks: Sendable {
    var beforePut: (@Sendable (ObjectKey) async -> Void)?
    var failPut: (@Sendable (ObjectKey) -> StorageError?)?
    var failDeletes = false
    var hiddenFromListing: String?
  }

  let inner: InMemoryStorageProvider
  private let hooks: Mutex<Hooks>

  init(inner: InMemoryStorageProvider = InMemoryStorageProvider(), hooks: Hooks = Hooks()) {
    self.inner = inner
    self.hooks = Mutex(hooks)
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  func update(_ change: (inout Hooks) -> Void) {
    hooks.withLock { change(&$0) }
  }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    let page = try await inner.list(prefix: prefix, after: cursor)
    guard let hidden = hooks.withLock({ $0.hiddenFromListing }) else { return page }
    return ListPage(objects: page.objects.filter { !$0.key.rawValue.hasPrefix(hidden) }, next: page.next)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    let current = hooks.withLock { $0 }
    await current.beforePut?(key)
    if let failure = current.failPut?(key) { throw failure }
    return try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    if hooks.withLock({ $0.failDeletes }) { throw .unavailable("scripted delete failure") }
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}
