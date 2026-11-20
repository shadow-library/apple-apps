import Foundation
import ShadowSync

/// Key index of one zone, kept from the change feed and from this device's own writes. The saved pair (entries, token) is consistent: every entry
/// stands for a record the feed or a successful write reported, and replaying the feed from the token reaches the same table.
/// A record counts only when its name is the one its path hashes to, so a record of another shape or a second record claiming a path is ignored.
actor CloudKitIndex {
  private typealias Outcome = Result<Bool, StorageError>

  private let client: any CloudKitZoneClient
  private let store: any CloudKitStateStore
  private let tuning: CloudKitTuning
  private let announce: @Sendable (CloudKitStorageCondition) -> Void
  private var loaded = false
  private var token: CloudKitChangeToken?
  private var zoneStatus = CloudKitZoneStatus.unknown
  private var accountChange: CloudKitAccountChange?
  private var userRecordName: String?
  private var accountChecked = false
  private var accountCheck: Task<Result<Void, StorageError>, Never>?
  private var entries: [ObjectKey: CloudKitIndexEntry] = [:]
  private var keysByName: [CloudKitRecordName: ObjectKey] = [:]
  private var sortedKeys: [ObjectKey]?
  private var running: Task<Outcome, Never>?
  private var putsDuringCatchUp: [ObjectKey: CloudKitIndexEntry] = [:]
  private var tombstones: [CloudKitRecordName: Date] = [:]
  private var dirty = false
  private var lastSave: Task<Result<Void, StorageError>, Never>?
  private(set) var joinedCatchUps = 0

  init(
    client: any CloudKitZoneClient, store: any CloudKitStateStore, tuning: CloudKitTuning, announce: @escaping @Sendable (CloudKitStorageCondition) -> Void = { _ in }
  ) {
    self.client = client
    self.store = store
    self.tuning = tuning
    self.announce = announce
  }

  var condition: CloudKitStorageCondition? {
    if let accountChange { return .accountChanged(accountChange) }
    if case .lost(let loss) = zoneStatus { return .zoneLost(loss) }
    return nil
  }

  func currentCondition() async throws(StorageError) -> CloudKitStorageCondition? {
    try await loadIfNeeded()
    return condition
  }

  /// Throws the condition's error, after checking once that the signed-in account is the one the index was read from.
  func usable(allowingLostZone: Bool = false) async throws(StorageError) {
    try await loadIfNeeded()
    try refuse(allowingLostZone: allowingLostZone)
    try await ensureAccountBound()
    try refuse(allowingLostZone: allowingLostZone)
  }

  private func refuse(allowingLostZone: Bool) throws(StorageError) {
    switch condition {
    case nil: return
    case .zoneLost where allowingLostZone: return
    case let condition?: throw condition.error
    }
  }

  /// After a sign-in event: the account may not be the one the index belongs to, as when the engine lost its state.
  func recheckAccount() async {
    accountChecked = false
    try? await usable()
  }

  var knowsZone: Bool { zoneStatus == .present }

  var isLost: Bool {
    if case .lost = zoneStatus { return true }
    return false
  }

  func modified(of key: ObjectKey) -> Date? {
    entries[key]?.modified
  }

  /// Returns whether the feed brought changes the table did not already hold.
  @discardableResult
  func catchUp() async throws(StorageError) -> Bool {
    try await usable()
    if let running {
      joinedCatchUps += 1
      return try await running.value.get()
    }
    let task = Task { await self.runCatchUp() }
    running = task
    return try await task.value.get()
  }

  func page(prefix: String, after cursor: ListCursor?) -> ListPage {
    let keys = orderedKeys()
    let prefixStart = Self.firstIndex(in: keys) { !$0.rawValue.utf8.lexicographicallyPrecedes(prefix.utf8) }
    let cursorStart = cursor.map { cursor in Self.firstIndex(in: keys) { cursor.token.utf8.lexicographicallyPrecedes($0.rawValue.utf8) } } ?? keys.startIndex
    var objects: [StorageObject] = []
    var more = false
    for key in keys[max(prefixStart, cursorStart)...] {
      guard key.hasPrefix(prefix) else { break }
      guard objects.count < tuning.listPageSize else {
        more = true
        break
      }
      if let entry = entries[key] { objects.append(StorageObject(key: key, size: entry.size)) }
    }
    return ListPage(objects: objects, next: more ? objects.last.map { ListCursor(token: $0.key.rawValue) } : nil)
  }

  func recordWrite(_ summary: CloudKitRecordSummary, key: ObjectKey) async throws(StorageError) {
    guard condition == nil else { return }
    let entry = CloudKitIndexEntry(key: key, size: summary.size, modified: summary.modified)
    tombstones[summary.name] = nil
    upsert(entry, name: summary.name)
    if running != nil { putsDuringCatchUp[key] = entry }
    try await noteZonePresent()
  }

  func recordDeletion(of key: ObjectKey) {
    let name = CloudKitRecordLayout.recordName(of: key)
    putsDuringCatchUp[key] = nil
    guard let entry = entries[key] else { return }
    tombstones[name] = entry.modified
    remove(key, name: name)
  }

  /// A read found no record. Only the entry the read was checking goes: one written since (or first seen since) stays.
  func recordMissing(_ key: ObjectKey, checked: Date?) {
    guard let checked, let entry = entries[key], entry.modified <= checked else { return }
    recordDeletion(of: key)
  }

  func noteZonePresent() async throws(StorageError) {
    guard zoneStatus == .unknown else { return }
    zoneStatus = .present
    try await persist()
  }

  /// A zone missing from a request sent before the zone was known means no vault exists yet; one sent while it was known, or one the user
  /// deleted, is a loss.
  func noteZoneMissing(_ loss: CloudKitZoneLoss, sentWhilePresent: Bool) async {
    guard loss != .missing || sentWhilePresent else { return }
    await noteZoneLost(loss)
  }

  /// Returns whether the loss is new.
  @discardableResult
  func noteZoneLost(_ loss: CloudKitZoneLoss) async -> Bool {
    try? await loadIfNeeded()
    if case .lost = zoneStatus { return false }
    zoneStatus = .lost(loss)
    clearTable()
    announce(.zoneLost(loss))
    try? await persist()
    return true
  }

  /// Returns whether the change is new. A sign-in from no account is not a change of account by itself; `recheckAccount()` decides.
  @discardableResult
  func noteAccountChange(_ change: CloudKitAccountChange) async -> Bool {
    try? await loadIfNeeded()
    if case .signedIn = change { return false }
    guard accountChange == nil else { return false }
    accountChange = change
    clearTable()
    announce(.accountChanged(change))
    try? await persist()
    return true
  }

  func zoneRecreated() async throws(StorageError) {
    try await loadIfNeeded()
    if let accountChange { throw CloudKitStorageCondition.accountChanged(accountChange).error }
    zoneStatus = .present
    clearTable()
    try await persist()
  }

  private func clearTable() {
    token = nil
    entries = [:]
    keysByName = [:]
    sortedKeys = nil
    tombstones = [:]
    putsDuringCatchUp = [:]
  }

  private func loadIfNeeded() async throws(StorageError) {
    guard !loaded else { return }
    let stored = try await store.load()
    guard !loaded else { return }
    loaded = true
    switch stored {
    case .absent:
      return
    case .unreadable:
      zoneStatus = .present
    case .state(let state) where !state.belongs(to: client.configuration):
      return
    case .state(let state) where !state.isCurrentFormat:
      zoneStatus = .present
    case .state(let state):
      token = state.token
      zoneStatus = state.zoneStatus
      accountChange = state.accountChange
      userRecordName = state.userRecordName
      for entry in state.entries { upsert(entry, name: CloudKitRecordLayout.recordName(of: entry.key)) }
    }
  }

  private func ensureAccountBound() async throws(StorageError) {
    guard !accountChecked else { return }
    if let accountCheck { return try await accountCheck.value.get() }
    let task = Task { await self.checkAccount() }
    accountCheck = task
    try await task.value.get()
  }

  private func checkAccount() async -> Result<Void, StorageError> {
    defer { accountCheck = nil }
    let current: String
    do throws(CloudKitZoneError) {
      current = try await client.currentUserRecordName()
    } catch {
      return .failure(Self.storageError(error))
    }
    if let condition { return .failure(condition.error) }
    accountChecked = true
    guard let bound = userRecordName else {
      userRecordName = current
      do throws(StorageError) {
        try await persist()
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    guard bound != current else { return .success(()) }
    let change = CloudKitAccountChange.switched(previous: bound, current: current)
    await noteAccountChange(change)
    return .failure(CloudKitStorageCondition.accountChanged(change).error)
  }

  private func runCatchUp() async -> Outcome {
    defer {
      running = nil
      putsDuringCatchUp = [:]
    }
    do throws(StorageError) {
      let changed = try await followFeed()
      if dirty { try await persist() }
      return .success(changed)
    } catch {
      if dirty, condition == nil { try? await persist() }
      return .failure(error)
    }
  }

  private func followFeed() async throws(StorageError) -> Bool {
    var rebuild: (table: [ObjectKey: CloudKitIndexEntry], token: CloudKitChangeToken?)?
    var rebuilds = 0
    var changed = false
    for _ in 0..<tuning.maxFeedPages {
      let batch: CloudKitChangeBatch
      let sentWhilePresent = zoneStatus == .present
      do throws(CloudKitZoneError) {
        batch = try await client.fetchChanges(since: rebuild.map(\.token) ?? token)
      } catch .changeTokenExpired {
        guard rebuild?.token != nil || rebuild == nil, rebuilds < tuning.maxRebuilds else { throw .unavailable("iCloud keeps refusing the zone's change tokens.") }
        rebuilds += 1
        rebuild = ([:], nil)
        continue
      } catch .zoneMissing(let loss) {
        return try await zoneMissing(loss, sentWhilePresent: sentWhilePresent)
      } catch {
        throw Self.storageError(error)
      }
      if let condition { throw condition.error }
      if var table = rebuild?.table {
        Self.apply(batch, to: &table)
        rebuild = (table, batch.token)
        guard !batch.moreComing else { continue }
        changed = swap(in: table) || changed
        rebuild = nil
      } else {
        changed = apply(batch) || changed
      }
      token = batch.token
      dirty = true
      if zoneStatus == .unknown { zoneStatus = .present }
      guard batch.moreComing else { return changed }
    }
    throw .unavailable("The iCloud change feed did not finish within \(tuning.maxFeedPages) pages.")
  }

  /// A put may have created the zone while the request was out; the next catch-up then reads it.
  private func zoneMissing(_ loss: CloudKitZoneLoss, sentWhilePresent: Bool) async throws(StorageError) -> Bool {
    await noteZoneMissing(loss, sentWhilePresent: sentWhilePresent)
    if let condition { throw condition.error }
    guard zoneStatus == .unknown else { return false }
    let changed = !entries.isEmpty
    clearTable()
    dirty = dirty || changed
    return changed
  }

  private func apply(_ batch: CloudKitChangeBatch) -> Bool {
    var changed = false
    for name in batch.deleted {
      tombstones[name] = nil
      guard let key = keysByName[name] else { continue }
      remove(key, name: name)
      changed = true
    }
    for summary in batch.changed {
      guard let entry = Self.entry(summary) else { continue }
      if let tombstone = tombstones[summary.name] {
        guard summary.modified > tombstone else { continue }
        tombstones[summary.name] = nil
      }
      if let existing = entries[entry.key], existing.modified > entry.modified || existing == entry { continue }
      upsert(entry, name: summary.name)
      changed = true
    }
    return changed
  }

  private static func apply(_ batch: CloudKitChangeBatch, to table: inout [ObjectKey: CloudKitIndexEntry]) {
    if !batch.deleted.isEmpty {
      let deleted = Set(batch.deleted)
      table = table.filter { !deleted.contains(CloudKitRecordLayout.recordName(of: $0.key)) }
    }
    for summary in batch.changed {
      guard let entry = entry(summary) else { continue }
      if let existing = table[entry.key], existing.modified > entry.modified { continue }
      table[entry.key] = entry
    }
  }

  /// Puts made while the zone was read again stay, unless the rebuilt table holds a newer version; deletions this device made since stay deleted
  /// until the feed reports them.
  private func swap(in rebuilt: [ObjectKey: CloudKitIndexEntry]) -> Bool {
    var table = rebuilt
    for (key, entry) in putsDuringCatchUp where (table[key]?.modified ?? .distantPast) <= entry.modified { table[key] = entry }
    let keysByRebuiltName = Dictionary(uniqueKeysWithValues: table.keys.map { (CloudKitRecordLayout.recordName(of: $0), $0) })
    var pending: [CloudKitRecordName: Date] = [:]
    for (name, deletedAt) in tombstones {
      guard let key = keysByRebuiltName[name], let entry = table[key], entry.modified <= deletedAt else { continue }
      table[key] = nil
      pending[name] = deletedAt
    }
    tombstones = pending
    let changed = table != entries
    entries = [:]
    keysByName = [:]
    sortedKeys = nil
    for (name, key) in keysByRebuiltName { if let entry = table[key] { upsert(entry, name: name) } }
    return changed
  }

  private static func entry(_ summary: CloudKitRecordSummary) -> CloudKitIndexEntry? {
    guard let key = ObjectKey(summary.path), CloudKitRecordLayout.recordName(of: key) == summary.name, summary.size >= 0 else { return nil }
    return CloudKitIndexEntry(key: key, size: summary.size, modified: summary.modified)
  }

  private func upsert(_ entry: CloudKitIndexEntry, name: CloudKitRecordName) {
    if entries[entry.key] == nil { sortedKeys = nil }
    entries[entry.key] = entry
    keysByName[name] = entry.key
  }

  private func remove(_ key: ObjectKey, name: CloudKitRecordName) {
    guard entries.removeValue(forKey: key) != nil else { return }
    keysByName[name] = nil
    sortedKeys = nil
  }

  /// The first index whose key satisfies `isPast`, which must hold for a suffix of the sorted keys.
  private static func firstIndex(in keys: [ObjectKey], where isPast: (ObjectKey) -> Bool) -> Int {
    var low = keys.startIndex
    var high = keys.endIndex
    while low < high {
      let middle = (low + high) / 2
      if isPast(keys[middle]) { high = middle } else { low = middle + 1 }
    }
    return low
  }

  private func orderedKeys() -> [ObjectKey] {
    if let sortedKeys { return sortedKeys }
    let ordered = entries.keys.sorted()
    sortedKeys = ordered
    return ordered
  }

  /// Saves run one after another in the order their snapshots were taken, so an older snapshot never lands after a newer one.
  private func persist() async throws(StorageError) {
    let state = CloudKitIndexState(
      configuration: client.configuration, token: token, zoneStatus: zoneStatus, accountChange: accountChange, userRecordName: userRecordName,
      entries: entries.values.sorted { $0.key < $1.key })
    dirty = false
    let previous = lastSave
    let store = store
    let save = Task { () async -> Result<Void, StorageError> in
      _ = await previous?.value
      do throws(StorageError) {
        try await store.save(state)
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    lastSave = save
    if case .failure(let error) = await save.value {
      dirty = true
      throw error
    }
  }

  static func storageError(_ error: CloudKitZoneError) -> StorageError {
    switch error {
    case .storage(let error): error
    case .zoneMissing(let loss): CloudKitStorageCondition.zoneLost(loss).error
    case .changeTokenExpired, .recordChanged, .recordMissing, .limitExceeded: .underlying(error.errorDescription ?? error.code)
    }
  }
}
