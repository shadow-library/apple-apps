import Foundation
import ShadowSync

/// Stores a vault in one zone of the private database, one record per object named `o-` + the SHA-256 of a domain, a zero byte and its key (`CloudKitRecordLayout`).
/// Listings are answered in key order from an index kept from the zone's change feed and this device's writes, saved through `stateStore`.
/// A zone this provider has never seen is created by the first put; a zone it saw and then lost, or an account that signed out or switched,
/// makes every call fail with `condition()` set until the runtime attaches again (`recreateZone()` after the user agrees).
public final class CloudKitStorageProvider: StorageProvider {
  public let capabilities: StorageCapabilities

  let index: CloudKitIndex

  private let client: any CloudKitZoneClient
  private let tuning: CloudKitTuning
  private let notices: Broadcast<Void>
  private let conditions: Broadcast<CloudKitStorageCondition>
  private let listener: Task<Void, Never>

  public convenience init(client: any CloudKitZoneClient, stateStore: any CloudKitStateStore) {
    self.init(client: client, stateStore: stateStore, tuning: CloudKitTuning())
  }

  init(client: any CloudKitZoneClient, stateStore: any CloudKitStateStore, tuning: CloudKitTuning) {
    let tuning = tuning.validated()
    let notices = Broadcast<Void>(policy: .bufferingNewest(1))
    let conditions = Broadcast<CloudKitStorageCondition>()
    let index = CloudKitIndex(client: client, store: stateStore, tuning: tuning) { condition in
      conditions.yield(condition)
      notices.yield(())
    }
    self.notices = notices
    self.conditions = conditions
    self.client = client
    self.index = index
    self.tuning = tuning
    capabilities = StorageCapabilities(
      pushesChangeNotices: true, supportsPutIfAbsent: true, hasChangeFeed: true, reportsServerTime: true, maxObjectBytes: tuning.maxObjectBytes, classPolicy: .iCloud)
    let events = client.events()
    listener = Task {
      for await event in events {
        await Self.handle(event, index: index, notices: notices)
      }
    }
  }

  deinit {
    listener.cancel()
    notices.finish()
    conditions.finish()
  }

  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    if cursor == nil { try await index.catchUp() } else { try await index.usable() }
    return await index.page(prefix: prefix, after: cursor)
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await index.usable()
    let name = CloudKitRecordLayout.recordName(of: key)
    let zoneKnown = await index.knowsZone
    let checked = await index.modified(of: key)
    let result: Result<CloudKitObjectRecord, CloudKitZoneError>
    do throws(CloudKitZoneError) {
      result = try await client.fetch([name])[name] ?? .failure(.recordMissing)
    } catch {
      result = .failure(error)
    }
    switch result {
    case .success(let record):
      return try CloudKitRecordLayout.data(of: record, key: key)
    case .failure(.recordMissing):
      await index.recordMissing(key, checked: checked)
      throw .notFound(key)
    case .failure(.zoneMissing(.missing)) where !zoneKnown:
      throw .notFound(key)
    case .failure(let error):
      throw await failure(error, sentWhilePresent: zoneKnown)
    }
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    guard data.count <= tuning.maxObjectBytes else { throw .tooLarge(key, limit: tuning.maxObjectBytes) }
    try await index.usable()
    let record = CloudKitObjectRecord(
      name: CloudKitRecordLayout.recordName(of: key), path: key.rawValue, size: data.count,
      payload: CloudKitRecordLayout.payload(of: data, inlineLimit: tuning.inlineLimit, partBytes: tuning.partBytes))
    let mode: CloudKitSaveMode = condition == .ifAbsent ? .ifAbsent : .overwrite
    let sentWhilePresent = await index.knowsZone
    var outcome = await save(record, mode: mode)
    if case .failure(.zoneMissing(.missing)) = outcome, !sentWhilePresent {
      try await createZone()
      outcome = await save(record, mode: mode)
      if case .failure(.zoneMissing(.missing)) = outcome { throw .unavailable("The vault's iCloud zone was created but cannot be written yet.") }
    }
    switch outcome {
    case .success(let summary):
      try await index.recordWrite(summary, key: key)
      return PutReceipt(serverTime: summary.modified)
    case .failure(.recordChanged) where mode == .ifAbsent:
      throw .alreadyExists(key)
    case .failure(.limitExceeded):
      throw .tooLarge(key, limit: tuning.maxObjectBytes)
    case .failure(let error):
      throw await failure(error, sentWhilePresent: sentWhilePresent)
    }
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    var seen: Set<ObjectKey> = []
    let unique = keys.filter { seen.insert($0).inserted }
    guard !unique.isEmpty else { return }
    try await index.usable()
    var firstFailure: StorageError?
    for start in stride(from: 0, to: unique.count, by: tuning.batchSize) {
      let batch = Array(unique[start..<min(start + tuning.batchSize, unique.count)])
      if let error = try await deleteSplitting(batch) { firstFailure = Self.preferred(firstFailure, error) }
    }
    if let firstFailure { throw firstFailure }
  }

  public func changeNotices() -> AsyncStream<Void> {
    notices.stream()
  }

  /// Yields each condition once, when it arises.
  public func conditionChanges() -> AsyncStream<CloudKitStorageCondition> {
    conditions.stream()
  }

  public func condition() async throws(StorageError) -> CloudKitStorageCondition? {
    try await index.currentCondition()
  }

  /// Creates the zone again after it was lost, with an empty index. Only after the user agreed: the vault's other copies may hold data the old zone held.
  public func recreateZone() async throws(StorageError) {
    try await index.usable(allowingLostZone: true)
    do throws(CloudKitZoneError) {
      try await client.ensureZone()
    } catch {
      throw Self.mapped(error)
    }
    try await index.zoneRecreated()
  }

  private func save(_ record: CloudKitObjectRecord, mode: CloudKitSaveMode) async -> Result<CloudKitRecordSummary, CloudKitZoneError> {
    do throws(CloudKitZoneError) {
      return try await client.save([record], mode: mode)[record.name] ?? .failure(.storage(.unavailable("iCloud did not answer for \(record.path).")))
    } catch {
      return .failure(error)
    }
  }

  /// Returns the batch's most telling per-record failure after recording every success; halves a batch CloudKit finds too large.
  private func deleteSplitting(_ keys: [ObjectKey]) async throws(StorageError) -> StorageError? {
    let names = Dictionary(uniqueKeysWithValues: keys.map { (CloudKitRecordLayout.recordName(of: $0), $0) })
    let zoneKnown = await index.knowsZone
    let results: [CloudKitRecordName: Result<Void, CloudKitZoneError>]
    do throws(CloudKitZoneError) {
      results = try await client.delete(Array(names.keys).sorted())
    } catch .limitExceeded where keys.count > 1 {
      let half = keys.count / 2
      let first = try await deleteSplitting(Array(keys[..<half]))
      let second = try await deleteSplitting(Array(keys[half...]))
      return Self.preferred(first, second)
    } catch .zoneMissing(.missing) where !zoneKnown {
      return nil
    } catch {
      throw await failure(error, sentWhilePresent: zoneKnown)
    }
    var worst: StorageError?
    for (name, key) in names.sorted(by: { $0.key < $1.key }) {
      switch results[name] {
      case .success, .failure(.recordMissing):
        await index.recordDeletion(of: key)
      case .failure(.zoneMissing(.missing)) where !zoneKnown:
        continue
      case .failure(let error):
        worst = Self.preferred(worst, await failure(error, sentWhilePresent: zoneKnown))
      case nil:
        worst = Self.preferred(worst, .unavailable("iCloud did not answer for \(key)."))
      }
    }
    return worst
  }

  /// The zone is created by the first put only while no request has ever found it; a zone lost meanwhile is not created again.
  private func createZone() async throws(StorageError) {
    try await index.usable()
    guard await !index.isLost else { throw .unavailable(CloudKitZoneLoss.missing.explanation) }
    do throws(CloudKitZoneError) {
      try await client.ensureZone()
    } catch {
      throw await failure(error, sentWhilePresent: false)
    }
    try await index.noteZonePresent()
  }

  private func failure(_ error: CloudKitZoneError, sentWhilePresent: Bool) async -> StorageError {
    if case .zoneMissing(let loss) = error { await index.noteZoneMissing(loss, sentWhilePresent: sentWhilePresent) }
    return Self.mapped(error)
  }

  private static func mapped(_ error: CloudKitZoneError) -> StorageError {
    CloudKitIndex.storageError(error)
  }

  /// A rate limit wins, so the caller waits as long as CloudKit asked.
  private static func preferred(_ current: StorageError?, _ next: StorageError?) -> StorageError? {
    guard let current else { return next }
    guard let next else { return current }
    if case .rateLimited = current { return current }
    if case .rateLimited = next { return next }
    return current
  }

  private static func handle(_ event: CloudKitZoneEvent, index: CloudKitIndex, notices: Broadcast<Void>) async {
    switch event {
    case .remoteChange:
      guard (try? await index.catchUp()) != false else { return }
      notices.yield(())
    case .zoneDeleted(let loss):
      await index.noteZoneLost(loss)
    case .accountChanged(.signedIn):
      await index.recheckAccount()
    case .accountChanged(let change):
      await index.noteAccountChange(change)
    }
  }
}
