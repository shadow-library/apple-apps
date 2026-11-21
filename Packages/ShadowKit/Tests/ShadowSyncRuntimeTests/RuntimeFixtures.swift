import Foundation
import Security
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowSync
import ShadowSyncCloudKit
import ShadowSyncRuntime
import ShadowTestSupport
import Synchronization

struct RuntimeFixtureFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

enum RuntimeFixture {
  static let note = kind("note")
  static let registry = SyncKernelSchema.registry(version: 1, adding: [EntitySchema(kind: note, shape: .record(fields: ["title": .register]), syncClass: .general)])
  static let start = Date(timeIntervalSince1970: 1_700_000_000)
  static let phone = ReplicaDevice(name: "Phone", platform: "iOS", appVersion: "1.0")
  static let tablet = ReplicaDevice(name: "Tablet", platform: "iOS", appVersion: "1.0")
  static let ringService = "com.shadow.apps.test.sync"

  static var iCloud: SyncProviderSettings {
    guard let configuration = try? CloudKitConfiguration(containerIdentifier: "iCloud.com.shadow.apps.test") else { preconditionFailure("fixture container is valid") }
    return .iCloud(SyncICloudSettings(configuration))
  }

  static func localFolder(_ name: String) -> SyncProviderSettings {
    .localFolder(SyncLocalFolderSettings(url: URL(filePath: "/tmp/shadow-runtime-fixture/\(name)", directoryHint: .isDirectory)))
  }

  static func kind(_ name: String) -> EntityKind {
    guard let kind = EntityKind(name) else { preconditionFailure("fixture kind is valid") }
    return kind
  }

  static func vault(_ name: String) -> VaultID {
    guard let vault = VaultID(name) else { preconditionFailure("fixture vault id is valid") }
    return vault
  }

  static func keyID(_ index: Int) -> KeyID {
    guard let id = KeyID(String(format: "00000000-0000-7000-8000-%012x", index)) else { preconditionFailure("fixture key id is valid") }
    return id
  }

  static func openStore() throws -> VaultStore {
    try VaultStore.open(.inMemory, registry: registry, migrations: SyncEngine.migrations, wallClock: { start })
  }

  static func stores(_ device: InMemoryKeychain.Device) -> SyncSecureStores {
    SyncSecureStores(
      ring: device.store(service: ringService, scope: .synced), credentials: device.store(service: "com.shadow.apps.test.sync.credentials", scope: .synced),
      marker: device.store(service: "com.shadow.apps.test.sync.device", scope: .device), tokens: device.store(service: "com.shadow.apps.test.sync.tokens", scope: .device))
  }

  static func ringKeys(_ device: InMemoryKeychain.Device, vault: VaultID) throws -> [String] {
    try device.store(service: ringService, scope: .synced).allKeys().filter { $0.hasPrefix("vault-key/\(vault.rawValue)/") }
  }

  static func hint(in provider: any StorageProvider) async throws -> VaultID? {
    do {
      return try VaultHint(decoding: try await provider.get(VaultPath.hint)).vault
    } catch StorageError.notFound {
      return nil
    }
  }
}

final class TemporaryDirectory: Sendable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appending(path: "shadow-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }

  func locationStore() throws -> SyncLocationStore {
    try SyncLocationStore(url: url.appending(path: "Sync/location.json"), outside: [url.appending(path: "Vaults/Default", directoryHint: .isDirectory)])
  }
}

final class AccountSwitch: Sendable {
  private let status: Mutex<SyncAccountStatus>

  init(_ status: SyncAccountStatus) {
    self.status = Mutex(status)
  }

  var current: SyncAccountStatus { status.withLock { $0 } }

  func set(_ status: SyncAccountStatus) {
    self.status.withLock { $0 = status }
  }
}

/// Answers the unlock probe from a script; the last answer repeats.
final class UnlockAnswers: Sendable {
  private let answers: Mutex<[Bool]>

  init(_ answers: [Bool]) {
    precondition(!answers.isEmpty, "the probe needs an answer")
    self.answers = Mutex(answers)
  }

  func next() -> Bool {
    answers.withLock { answers in answers.count > 1 ? answers.removeFirst() : answers[0] }
  }

  func set(_ answers: [Bool]) {
    self.answers.withLock { $0 = answers }
  }
}

final class Flag: Sendable {
  private let value: Mutex<Bool>

  init(_ value: Bool) {
    self.value = Mutex(value)
  }

  var isSet: Bool { value.withLock { $0 } }

  func set(_ value: Bool) {
    self.value.withLock { $0 = value }
  }
}

struct RuntimeDevice {
  let keychain: InMemoryKeychain.Device
  let directory: TemporaryDirectory
  let startup: SyncStartup

  init(
    _ keychain: InMemoryKeychain.Device, provider: any StorageProvider, automatic: SyncProviderSettings? = RuntimeFixture.iCloud,
    account: AccountSwitch = AccountSwitch(.available(SyncAccountBinding(kind: .iCloud, account: "user-one"))), unlocked: UnlockAnswers = UnlockAnswers([true]),
    stores: SyncSecureStores? = nil
  ) throws {
    self.keychain = keychain
    directory = try TemporaryDirectory()
    startup = SyncStartup(
      SyncStartupEnvironment(
        locationStore: try directory.locationStore(), stores: stores ?? RuntimeFixture.stores(keychain), automatic: automatic, provider: { _ in provider },
        account: { _ in account.current }, hasUnlockedSinceBoot: { unlocked.next() }))
  }
}

/// Fails every call with the status the keychain returns before the first unlock after a restart.
struct LockedSecureStore: SecureStore {
  private static let locked = SecureStoreError.unexpectedStatus(errSecInteractionNotAllowed)

  func data(forKey key: String) throws(SecureStoreError) -> Data? { throw Self.locked }
  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) { throw Self.locked }
  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool { throw Self.locked }
  func removeValue(forKey key: String) throws(SecureStoreError) { throw Self.locked }
  func allKeys() throws(SecureStoreError) -> [String] { throw Self.locked }
}

/// Answers as the data protection keychain answers a build without an application identifier: reads find nothing, and only adding, replacing or
/// deleting an item fails with `errSecMissingEntitlement`. `refusesReads` fails reads too, as a keychain may for an access group the build lacks.
struct MissingEntitlementSecureStore: SecureStore {
  private static let refused = SecureStoreError.unexpectedStatus(errSecMissingEntitlement)

  var refusesReads = false

  static func stores() -> SyncSecureStores {
    SyncSecureStores(ring: Self(), credentials: Self(), marker: Self(), tokens: Self())
  }

  func data(forKey key: String) throws(SecureStoreError) -> Data? {
    if refusesReads { throw Self.refused }
    return nil
  }

  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) { throw Self.refused }
  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool { throw Self.refused }
  func removeValue(forKey key: String) throws(SecureStoreError) { throw Self.refused }

  func allKeys() throws(SecureStoreError) -> [String] {
    if refusesReads { throw Self.refused }
    return []
  }
}

/// Holds every put of the vault hint until `writers` of them have arrived, so concurrent creators all pass discovery before any hint exists.
final class HintRaceProvider: StorageProvider {
  private struct State {
    var arrived = 0
    var waiting: [CheckedContinuation<Void, Never>] = []
  }

  let inner: InMemoryStorageProvider
  private let writers: Int
  private let state = Mutex(State())

  init(inner: InMemoryStorageProvider = InMemoryStorageProvider(), writers: Int) {
    self.inner = inner
    self.writers = writers
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    if key == VaultPath.hint { await arrive() }
    return try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }

  private func arrive() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let released = state.withLock { state -> [CheckedContinuation<Void, Never>] in
        state.arrived += 1
        state.waiting.append(continuation)
        guard state.arrived >= writers else { return [] }
        defer { state.waiting = [] }
        return state.waiting
      }
      for waiter in released { waiter.resume() }
    }
  }
}

final class ScriptedProvider: StorageProvider {
  struct Script: Sendable {
    var failingGets = 0
    var failingPuts = 0
    var putFailure = StorageError.unavailable("scripted failure")
    var writesBeforeFailing = false
    var supportsPutIfAbsent: Bool?
    var afterHintPut: (@Sendable (InMemoryStorageProvider) async -> Void)?
    var beforeHintPut: (@Sendable (InMemoryStorageProvider) async -> Void)?
  }

  let inner: InMemoryStorageProvider
  private let script: Mutex<Script>

  init(inner: InMemoryStorageProvider = InMemoryStorageProvider(), script: Script) {
    self.inner = inner
    self.script = Mutex(script)
  }

  var capabilities: StorageCapabilities {
    let base = inner.capabilities
    let atomic = script.withLock { $0.supportsPutIfAbsent } ?? base.supportsPutIfAbsent
    return StorageCapabilities(
      pushesChangeNotices: base.pushesChangeNotices, supportsPutIfAbsent: atomic, hasChangeFeed: base.hasChangeFeed, reportsServerTime: base.reportsServerTime,
      maxObjectBytes: base.maxObjectBytes, classPolicy: base.classPolicy)
  }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    let fails = script.withLock { script in
      guard script.failingGets > 0 else { return false }
      script.failingGets -= 1
      return true
    }
    if fails { throw .unavailable("scripted failure") }
    return try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    let (failure, writes, before, after) = script.withLock {
      script -> (StorageError?, Bool, (@Sendable (InMemoryStorageProvider) async -> Void)?, (@Sendable (InMemoryStorageProvider) async -> Void)?) in
      let isHint = key == VaultPath.hint
      guard script.failingPuts > 0 else { return (nil, false, isHint ? script.beforeHintPut : nil, isHint ? script.afterHintPut : nil) }
      script.failingPuts -= 1
      return (script.putFailure, script.writesBeforeFailing, isHint ? script.beforeHintPut : nil, nil)
    }
    await before?(inner)
    if let failure {
      if writes { _ = try await inner.put(key, data: data, condition: condition) }
      throw failure
    }
    let receipt = try await inner.put(key, data: data, condition: condition)
    await after?(inner)
    return receipt
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}

extension InMemoryStorageProvider {
  var isUntouched: Bool {
    let counts = callCounts
    return counts.list + counts.get + counts.put + counts.delete == 0
  }
}
