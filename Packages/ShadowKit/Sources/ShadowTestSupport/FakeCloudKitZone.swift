import Foundation
import ShadowSync
import ShadowSyncCloudKit
import Synchronization

/// An in-process CloudKit zone behind `CloudKitZoneClient`. It models change tokens and their expiry, zone deletion and re-creation, quota,
/// rate limiting with a retry-after, account sign-out and switching, per-record and per-request size limits, and injected failures.
/// Several providers may share one fake, as devices share one account.
public final class FakeCloudKitZone: CloudKitZoneClient {
  public enum Operation: Sendable, Hashable, CaseIterable {
    case ensureZone
    case fetchChanges
    case fetch
    case save
    case delete
    case accountStatus
    case currentUser
  }

  public struct Limits: Sendable {
    public var maxInlineBytes = 1_000_000
    public var maxAssetBytes = 50_000_000
    public var maxRecordsPerRequest = 250
    public var feedPageSize = 400
    public var quotaBytes: Int?

    public init() {}
  }

  fileprivate struct StoredRecord {
    var record: CloudKitObjectRecord
    var modified: Date
    var sequence: UInt64
  }

  fileprivate struct Account {
    var zoneExists = false
    var zoneEpoch: UInt64 = 0
    var lostReason: CloudKitZoneLoss?
    var records: [CloudKitRecordName: StoredRecord] = [:]
    var tombstones: [CloudKitRecordName: UInt64] = [:]
    var sequence: UInt64 = 0
    var tokenGeneration: UInt64 = 0
  }

  fileprivate struct State {
    var accounts: [String: Account] = [:]
    var user: String? = "user-1"
    var limits = Limits()
    var injected: [Operation: [CloudKitZoneError]] = [:]
    var failingRecords: [CloudKitRecordName: CloudKitZoneError] = [:]
    var calls: [Operation: Int] = [:]
    var batches: [Operation: [Int]] = [:]
    var tick: Int64 = 0
  }

  public let configuration: CloudKitConfiguration

  private let state = Mutex(State())
  private let subscribers = Mutex<[UUID: AsyncStream<CloudKitZoneEvent>.Continuation]>([:])
  private let epoch: Date

  public init(configuration: CloudKitConfiguration? = nil, limits: Limits = Limits(), epoch: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
    self.configuration = configuration ?? Self.defaultConfiguration
    self.epoch = epoch
    state.withLock { $0.limits = limits }
  }

  private static var defaultConfiguration: CloudKitConfiguration {
    guard let configuration = try? CloudKitConfiguration(containerIdentifier: "iCloud.com.shadow.apps.fake") else { preconditionFailure("the fake's container is valid") }
    return configuration
  }

  public func configureLimits(_ change: (inout Limits) -> Void) {
    state.withLock { change(&$0.limits) }
  }

  /// The next `times` calls of `operation` fail with `error` before touching the zone.
  public func inject(_ error: CloudKitZoneError, on operation: Operation, times: Int = 1) {
    state.withLock { $0.injected[operation, default: []] += Array(repeating: error, count: times) }
  }

  /// Every save or delete of `name` fails with `error` until cleared with nil.
  public func failRecord(_ name: CloudKitRecordName, with error: CloudKitZoneError?) {
    state.withLock { $0.failingRecords[name] = error }
  }

  /// Every token issued so far stops working and the deletions it would have reported are forgotten.
  public func expireTokens() {
    state.withLock { state in
      state.updateAccount { account in
        account.tokenGeneration += 1
        account.tombstones = [:]
      }
    }
  }

  public func deleteZone(_ loss: CloudKitZoneLoss = .missing, notify: Bool = true) {
    state.withLock { state in
      state.updateAccount { account in
        account.zoneExists = false
        account.lostReason = loss
        account.records = [:]
        account.tombstones = [:]
      }
    }
    if notify { emit(.zoneDeleted(loss)) }
  }

  public func signOut() {
    let previous = state.withLock { state in
      defer { state.user = nil }
      return state.user
    }
    if let previous { emit(.accountChanged(.signedOut(previous: previous))) }
  }

  /// Signs in to `user`, whose zone is separate from every other account's. Reports a switch when another account was signed in, unless
  /// `notify` is false, as when the change happened while the app was not running.
  public func signIn(_ user: String, notify: Bool = true) {
    let previous = state.withLock { state in
      defer { state.user = user }
      return state.user
    }
    guard notify else { return }
    if let previous, previous != user { emit(.accountChanged(.switched(previous: previous, current: user))) }
    if previous == nil { emit(.accountChanged(.signedIn(current: user))) }
  }

  public func pushHint() {
    emit(.remoteChange)
  }

  /// Delivers `event` as CloudKit would, whatever the account state.
  public func send(_ event: CloudKitZoneEvent) {
    emit(event)
  }

  public func callCount(_ operation: Operation) -> Int {
    state.withLock { $0.calls[operation] ?? 0 }
  }

  /// The number of records each call of `operation` carried.
  public func batchSizes(_ operation: Operation) -> [Int] {
    state.withLock { $0.batches[operation] ?? [] }
  }

  public var zoneExists: Bool {
    state.withLock { state in state.user.flatMap { state.accounts[$0]?.zoneExists } ?? false }
  }

  public var storedBytes: Int {
    state.withLock { state in state.user.flatMap { state.accounts[$0] }.map(Self.usedBytes) ?? 0 }
  }

  public func storedRecord(_ name: CloudKitRecordName) -> CloudKitObjectRecord? {
    state.withLock { state in state.user.flatMap { state.accounts[$0]?.records[name]?.record } }
  }

  /// Writes a record as another device or another app would, bypassing every check.
  public func seed(_ record: CloudKitObjectRecord) {
    state.withLock { state in
      state.tick += 1
      let modified = epoch.addingTimeInterval(Double(state.tick) / 1000)
      state.updateAccount { account in
        account.zoneExists = true
        account.sequence += 1
        account.tombstones[record.name] = nil
        account.records[record.name] = StoredRecord(record: record, modified: modified, sequence: account.sequence)
      }
    }
  }

  public func ensureZone() async throws(CloudKitZoneError) {
    try state.withLock { state throws(CloudKitZoneError) in
      try state.begin(.ensureZone, count: 0)
      state.updateAccount { account in
        guard !account.zoneExists else { return }
        account.zoneExists = true
        account.lostReason = nil
        account.zoneEpoch += 1
      }
    }
  }

  public func fetchChanges(since token: CloudKitChangeToken?) async throws(CloudKitZoneError) -> CloudKitChangeBatch {
    try state.withLock { state throws(CloudKitZoneError) in
      try state.begin(.fetchChanges, count: 0)
      let pageSize = max(1, state.limits.feedPageSize)
      return try state.withZone { account throws(CloudKitZoneError) in
        var after: UInt64 = 0
        if let token {
          guard let decoded = Self.decode(token), decoded.epoch == account.zoneEpoch, decoded.generation == account.tokenGeneration else { throw .changeTokenExpired }
          after = decoded.sequence
        }
        var items: [(sequence: UInt64, change: Change)] = account.records.values.filter { $0.sequence > after }.map { ($0.sequence, .changed($0)) }
        if token != nil { items += account.tombstones.filter { $0.value > after }.map { ($0.value, .deleted($0.key)) } }
        items.sort { $0.sequence < $1.sequence }
        let page = items.prefix(pageSize)
        let moreComing = items.count > page.count
        let reached = moreComing ? page.last?.sequence ?? after : account.sequence
        var changed: [CloudKitRecordSummary] = []
        var deleted: [CloudKitRecordName] = []
        for item in page {
          switch item.change {
          case .changed(let stored): changed.append(Self.summary(stored))
          case .deleted(let name): deleted.append(name)
          }
        }
        return CloudKitChangeBatch(
          changed: changed, deleted: deleted, token: Self.encode(epoch: account.zoneEpoch, generation: account.tokenGeneration, sequence: reached), moreComing: moreComing)
      }
    }
  }

  public func fetch(_ names: [CloudKitRecordName]) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<CloudKitObjectRecord, CloudKitZoneError>] {
    try state.withLock { state throws(CloudKitZoneError) in
      try state.begin(.fetch, count: names.count)
      return try state.withZone { account throws(CloudKitZoneError) in
        Dictionary(names.map { name in (name, account.records[name].map { .success($0.record) } ?? .failure(.recordMissing)) }) { first, _ in first }
      }
    }
  }

  public func save(
    _ records: [CloudKitObjectRecord], mode: CloudKitSaveMode
  ) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<CloudKitRecordSummary, CloudKitZoneError>] {
    try state.withLock { state throws(CloudKitZoneError) in
      try state.begin(.save, count: records.count)
      let limits = state.limits
      let failing = state.failingRecords
      var tick = state.tick
      defer { state.tick = tick }
      return try state.withZone { account throws(CloudKitZoneError) in
        var outcomes: [CloudKitRecordName: Result<CloudKitRecordSummary, CloudKitZoneError>] = [:]
        for record in records {
          if let error = failing[record.name] {
            outcomes[record.name] = .failure(error)
            continue
          }
          if let error = Self.sizeViolation(record, limits: limits) {
            outcomes[record.name] = .failure(error)
            continue
          }
          if mode == .ifAbsent, account.records[record.name] != nil {
            outcomes[record.name] = .failure(.recordChanged)
            continue
          }
          if let quota = limits.quotaBytes, Self.usedBytes(account) - (account.records[record.name]?.record.size ?? 0) + record.size > quota {
            outcomes[record.name] = .failure(.storage(.quotaExceeded))
            continue
          }
          tick += 1
          account.sequence += 1
          account.tombstones[record.name] = nil
          let stored = StoredRecord(record: record, modified: epoch.addingTimeInterval(Double(tick) / 1000), sequence: account.sequence)
          account.records[record.name] = stored
          outcomes[record.name] = .success(Self.summary(stored))
        }
        return outcomes
      }
    }
  }

  public func delete(_ names: [CloudKitRecordName]) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<Void, CloudKitZoneError>] {
    try state.withLock { state throws(CloudKitZoneError) in
      try state.begin(.delete, count: names.count)
      let failing = state.failingRecords
      return try state.withZone { account throws(CloudKitZoneError) in
        var outcomes: [CloudKitRecordName: Result<Void, CloudKitZoneError>] = [:]
        for name in names {
          if let error = failing[name] {
            outcomes[name] = .failure(error)
            continue
          }
          outcomes[name] = .success(())
          guard account.records.removeValue(forKey: name) != nil else { continue }
          account.sequence += 1
          account.tombstones[name] = account.sequence
        }
        return outcomes
      }
    }
  }

  public func accountStatus() async throws(CloudKitZoneError) -> CloudKitAccountStatus {
    try state.withLock { state throws(CloudKitZoneError) in
      try state.begin(.accountStatus, count: 0, requiresAccount: false)
      return state.user == nil ? .noAccount : .available
    }
  }

  public func currentUserRecordName() async throws(CloudKitZoneError) -> String {
    try state.withLock { state throws(CloudKitZoneError) in
      try state.begin(.currentUser, count: 0)
      guard let user = state.user else { throw .storage(.unauthenticated) }
      return user
    }
  }

  public func events() -> AsyncStream<CloudKitZoneEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: CloudKitZoneEvent.self)
    let id = UUID()
    continuation.onTermination = { [weak self] _ in self?.subscribers.withLock { _ = $0.removeValue(forKey: id) } }
    subscribers.withLock { $0[id] = continuation }
    return stream
  }

  fileprivate enum Change {
    case changed(StoredRecord)
    case deleted(CloudKitRecordName)
  }

  private func emit(_ event: CloudKitZoneEvent) {
    for continuation in subscribers.withLock({ Array($0.values) }) { continuation.yield(event) }
  }

  private static func usedBytes(_ account: Account) -> Int {
    account.records.values.reduce(0) { $0 + $1.record.size }
  }

  private static func summary(_ stored: StoredRecord) -> CloudKitRecordSummary {
    CloudKitRecordSummary(name: stored.record.name, path: stored.record.path, size: stored.record.size, modified: stored.modified)
  }

  private static func sizeViolation(_ record: CloudKitObjectRecord, limits: Limits) -> CloudKitZoneError? {
    switch record.payload {
    case .inline(let bytes): bytes.count > limits.maxInlineBytes ? .limitExceeded : nil
    case .parts(let parts): parts.contains { $0.count > limits.maxAssetBytes } ? .limitExceeded : nil
    }
  }

  private static func encode(epoch: UInt64, generation: UInt64, sequence: UInt64) -> CloudKitChangeToken {
    var data = Data()
    for value in [epoch, generation, sequence] { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    return CloudKitChangeToken(data: data)
  }

  private static func decode(_ token: CloudKitChangeToken) -> (epoch: UInt64, generation: UInt64, sequence: UInt64)? {
    guard token.data.count == 24 else { return nil }
    let bytes = Array(token.data)
    let words = stride(from: 0, to: 24, by: 8).map { start in bytes[start..<start + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
    return (words[0], words[1], words[2])
  }
}

extension FakeCloudKitZone.State {
  fileprivate mutating func begin(_ operation: FakeCloudKitZone.Operation, count: Int, requiresAccount: Bool = true) throws(CloudKitZoneError) {
    calls[operation, default: 0] += 1
    if count > 0 { batches[operation, default: []].append(count) }
    if var queued = injected[operation], !queued.isEmpty {
      let error = queued.removeFirst()
      injected[operation] = queued
      throw error
    }
    if requiresAccount, user == nil { throw .storage(.unauthenticated) }
    if count > limits.maxRecordsPerRequest { throw .limitExceeded }
  }

  fileprivate mutating func withAccount<T>(_ body: (inout FakeCloudKitZone.Account) throws(CloudKitZoneError) -> T) throws(CloudKitZoneError) -> T {
    guard let user else { throw .storage(.unauthenticated) }
    var account = accounts[user] ?? FakeCloudKitZone.Account()
    defer { accounts[user] = account }
    return try body(&account)
  }

  fileprivate mutating func updateAccount(_ body: (inout FakeCloudKitZone.Account) -> Void) {
    guard let user else { return }
    var account = accounts[user] ?? FakeCloudKitZone.Account()
    body(&account)
    accounts[user] = account
  }

  fileprivate mutating func withZone<T>(_ body: (inout FakeCloudKitZone.Account) throws(CloudKitZoneError) -> T) throws(CloudKitZoneError) -> T {
    try withAccount { account throws(CloudKitZoneError) -> T in
      guard account.zoneExists else { throw .zoneMissing(account.lostReason == .purged ? .purged : .missing) }
      return try body(&account)
    }
  }
}
