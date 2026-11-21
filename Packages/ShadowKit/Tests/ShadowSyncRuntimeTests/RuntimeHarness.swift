import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Synchronization

@testable import ShadowSyncRuntime

/// Wraps an in-memory provider with scripted failures, holds on the next download listing or replica put, call counts and change notices.
final class ControlledProvider: StorageProvider {
  enum Operation: Sendable, Hashable {
    case list
    case get
    case put
    case delete
  }

  enum Hold: Sendable, Hashable {
    case download
    case replicaPut
  }

  private struct State {
    var failures: [Operation: [StorageError]] = [:]
    var putFailure: StorageError?
    var downloads = 0
    var replicaPuts = 0
    var inFlight = 0
    var maximumInFlight = 0
    var holds: Set<Hold> = []
    var held: CheckedContinuation<Void, Never>?
    var holdWatchers: [CheckedContinuation<Void, Never>] = []
    var notices: [Int: AsyncStream<Void>.Continuation] = [:]
    var nextNoticeID = 0
  }

  let inner: InMemoryStorageProvider
  private let state = Mutex(State())

  init(inner: InMemoryStorageProvider = InMemoryStorageProvider()) {
    self.inner = inner
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  /// Listings of every replica's files, which only a download makes.
  var downloads: Int { state.withLock { $0.downloads } }
  var replicaPuts: Int { state.withLock { $0.replicaPuts } }
  var maximumInFlight: Int { state.withLock { $0.maximumInFlight } }

  func fail(_ operation: Operation, with error: StorageError, times: Int = 1) {
    state.withLock { $0.failures[operation, default: []] += Array(repeating: error, count: times) }
  }

  func failPuts(with error: StorageError?) {
    state.withLock { $0.putFailure = error }
  }

  func holdNext(_ hold: Hold) {
    state.withLock { _ = $0.holds.insert(hold) }
  }

  func waitUntilHeld() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let isHeld = state.withLock { state in
        guard state.held == nil else { return true }
        state.holdWatchers.append(continuation)
        return false
      }
      if isHeld { continuation.resume() }
    }
  }

  func releaseHeld() {
    state.withLock { state in
      defer { state.held = nil }
      return state.held
    }?.resume()
  }

  func notify() {
    state.withLock { state in
      for notice in state.notices.values { notice.yield() }
    }
  }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    let holds = begin(.list) { state in
      guard prefix == VaultPath.replicasPrefix, cursor == nil else { return false }
      state.downloads += 1
      return state.holds.remove(.download) != nil
    }
    defer { end() }
    if holds { await hold() }
    try failure(.list)
    return try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    _ = begin(.get) { _ in false }
    defer { end() }
    try failure(.get)
    return try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    let holds = begin(.put) { state in
      guard key.rawValue.hasPrefix(VaultPath.replicasPrefix) else { return false }
      return state.holds.remove(.replicaPut) != nil
    }
    defer { end() }
    if holds { await hold() }
    try failure(.put)
    if let putFailure = state.withLock({ $0.putFailure }) { throw putFailure }
    let receipt = try await inner.put(key, data: data, condition: condition)
    if key.rawValue.hasPrefix(VaultPath.replicasPrefix) { state.withLock { $0.replicaPuts += 1 } }
    return receipt
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    _ = begin(.delete) { _ in false }
    defer { end() }
    try failure(.delete)
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    state.withLock { state in
      state.notices[state.nextNoticeID] = continuation
      state.nextNoticeID += 1
    }
    return stream
  }

  private func begin(_ operation: Operation, _ body: (inout State) -> Bool) -> Bool {
    state.withLock { state in
      state.inFlight += 1
      state.maximumInFlight = max(state.maximumInFlight, state.inFlight)
      return body(&state)
    }
  }

  private func end() {
    state.withLock { $0.inFlight -= 1 }
  }

  private func failure(_ operation: Operation) throws(StorageError) {
    let error = state.withLock { state -> StorageError? in
      guard var queued = state.failures[operation], !queued.isEmpty else { return nil }
      let error = queued.removeFirst()
      state.failures[operation] = queued
      return error
    }
    if let error { throw error }
  }

  private func hold() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let watchers = state.withLock { state in
        state.held = continuation
        defer { state.holdWatchers = [] }
        return state.holdWatchers
      }
      for watcher in watchers { watcher.resume() }
    }
  }
}

struct RuntimeHarness {
  static let userOne = SyncAccountBinding(kind: .iCloud, account: "user-one")
  static let userTwo = SyncAccountBinding(kind: .iCloud, account: "user-two")

  let clock: ManualClock
  let keychain: InMemoryKeychain.Device
  let directory: TemporaryDirectory
  let store: VaultStore
  let runtime: SyncRuntime

  init(
    _ keychain: InMemoryKeychain.Device, provider: any StorageProvider, account: AccountSwitch = AccountSwitch(.available(Self.userOne)),
    directory: TemporaryDirectory? = nil, store: VaultStore? = nil, trustedClock: TrustedClock = TrustedClock(wallClock: { RuntimeFixture.start }),
    wallClock: @escaping @Sendable () -> Date = { RuntimeFixture.start }, clock: ManualClock = ManualClock()
  ) throws {
    try self.init(
      keychain, makeProvider: { _ in provider }, account: account, directory: directory, store: store, trustedClock: trustedClock, wallClock: wallClock, clock: clock)
  }

  init(
    _ keychain: InMemoryKeychain.Device, makeProvider: @escaping @Sendable (SyncProviderSettings) -> any StorageProvider,
    account: AccountSwitch = AccountSwitch(.available(Self.userOne)), directory: TemporaryDirectory? = nil, store: VaultStore? = nil,
    trustedClock: TrustedClock = TrustedClock(wallClock: { RuntimeFixture.start }), wallClock: @escaping @Sendable () -> Date = { RuntimeFixture.start },
    clock: ManualClock = ManualClock()
  ) throws {
    self.clock = clock
    self.keychain = keychain
    let directory = try directory ?? TemporaryDirectory()
    self.directory = directory
    let store = try store ?? RuntimeFixture.openStore()
    self.store = store
    let environment = SyncStartupEnvironment(
      locationStore: try directory.locationStore(), stores: RuntimeFixture.stores(keychain), automatic: RuntimeFixture.iCloud, provider: { makeProvider($0) },
      account: { _ in account.current }, hasUnlockedSinceBoot: { true })
    runtime = SyncRuntime(
      environment: environment, store: store, device: RuntimeFixture.phone, trustedClock: trustedClock, clock: clock, wallClock: wallClock)
  }

  static func fileStore(
    in directory: TemporaryDirectory, backup: StoreBackupPolicy = .adjustable, wallClock: @escaping @Sendable () -> Date = { RuntimeFixture.start }
  ) throws -> VaultStore {
    try VaultStore.open(
      .file(vaultDirectory(of: directory).appending(path: "vault.sqlite")), registry: RuntimeFixture.registry, migrations: SyncEngine.migrations,
      wallClock: wallClock, backup: backup)
  }

  static func vaultDirectory(of directory: TemporaryDirectory) -> URL {
    directory.url.appending(path: "Vaults/Default", directoryHint: .isDirectory)
  }

  func write(_ name: String) async throws {
    guard let key = EntityKey(name) else { throw RuntimeFixtureFailure("fixture key is valid") }
    try await store.write { transaction in _ = try transaction.set(EntityRef(kind: RuntimeFixture.note, key: key), ["title": .string(name)]) }
    await runtime.localWrite()
  }

  /// Moves time and runs whatever is due at once, without waiting for a timer.
  func advance(by duration: Duration) async {
    clock.advance(by: duration)
    await runtime.settle()
  }

  /// Moves time and leaves the work to the runtime's own timer: returns once `effect` holds and the run it started is over.
  func advanceTimer(by duration: Duration, until effect: @Sendable () async -> Bool) async throws -> Bool {
    clock.advance(by: duration)
    for _ in 0..<1_000 {
      if await effect() {
        await runtime.idle()
        return true
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  /// Gives a stray timer real time to act before an assertion that nothing ran.
  func quiesce() async throws {
    try await Task.sleep(for: .milliseconds(100))
    await runtime.idle()
  }

  func hasPendingChanges() async throws -> Bool {
    try await !store.pendingChanges(limit: 1).isEmpty
  }

  /// For effects that arrive through a provider's stream rather than through a call.
  func eventually(_ condition: @Sendable () async -> Bool) async throws -> Bool {
    for _ in 0..<500 {
      if await condition() { return true }
      await runtime.settle()
      try await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  static func isExcludedFromBackup(_ url: URL) throws -> Bool {
    var fresh = url
    fresh.removeAllCachedResourceValues()
    return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
  }

  /// The flag settles eventually on macOS.
  static func backupFlagSettles(on expected: Bool, _ url: URL) async throws -> Bool {
    for _ in 0..<6_000 {
      if try isExcludedFromBackup(url) == expected { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }
}

final class Counter: Sendable {
  private let count = Mutex(0)

  var value: Int { count.withLock { $0 } }

  func increment() {
    count.withLock { $0 += 1 }
  }
}
