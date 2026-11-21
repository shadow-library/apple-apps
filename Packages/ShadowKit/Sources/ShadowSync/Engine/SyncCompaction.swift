import Foundation
import GRDB
import ShadowCore
import ShadowStore

enum SyncCompactionStep: Sendable, Equatable, CaseIterable {
  case settled
  case announced
  case partPut
  case allPartsPut
  case completed
  case manifestPut
  case deleted
  case marked
}

struct SyncCompactionContext: Sendable {
  let store: VaultStore
  let provider: any StorageProvider
  let vault: VaultID
  let lifecycle: ReplicaLifecycle
  let trustedClock: TrustedClock
  let configuration: SyncConfiguration
  let replica: ReplicaID
  let key: VaultKey
  let now: @Sendable () -> Date
  let checkpoint: @Sendable (SyncCompactionStep) async throws(SyncError) -> Void
  let putManifest: @Sendable (VaultKey, ReplicaID) async throws(SyncError) -> Void

  var millis: Int64 {
    max(0, Int64((now().timeIntervalSince1970 * 1_000).rounded(.down)))
  }
}

private struct SyncSealedBase {
  let point: StreamPoint
  let parts: [SealedFile]
}

private enum SyncSealResult {
  case postponed
  case empty
  case sealed(SyncSealedBase)
}

private enum SyncCompactionStage {
  case postponed
  case completed(StreamPoint)
  case none
}

/// Deletes only names recorded in this replica's upload history, never by prefix: a second writer sharing the id keeps files of its own there.
struct SyncCompactor {
  static let deleteBatch = 256

  let context: SyncCompactionContext

  /// Cleanup runs whatever becomes of a new base, so a base that cannot be made yet never stops deletions the current base already covers.
  func run(force: Bool, listing: [StorageObject]) async throws(SyncError) -> SyncCompactionOutcome {
    try await context.checkpoint(.settled)
    let stage: SyncCompactionStage
    do {
      stage = try await compactIfNeeded(force: force, listing: listing)
    } catch {
      guard Self.leavesCleanupPossible(error) else { throw error }
      _ = try await cleanUp()
      throw error
    }
    let (segments, bases) = try await cleanUp()
    switch stage {
    case .completed(let point):
      return .compacted(base: point, deletedSegments: segments, deletedBases: bases)
    case .postponed where segments + bases == 0:
      return .postponed
    case .none where segments + bases == 0:
      return .notNeeded
    case .postponed, .none:
      try await context.putManifest(context.key, context.replica)
      try await context.checkpoint(.manifestPut)
      return .cleaned(deletedSegments: segments, deletedBases: bases)
    }
  }

  private static func leavesCleanupPossible(_ error: SyncError) -> Bool {
    switch error {
    case .baseTooLarge, .syncClassRefused, .storage: true
    default: false
    }
  }

  private func compactIfNeeded(force: Bool, listing: [StorageObject]) async throws(SyncError) -> SyncCompactionStage {
    switch try await resume() {
    case .postponed: return .postponed
    case .completed(let point): return .completed(point)
    case .none: break
    }
    guard try await isNeeded(force: force, listing: listing) else { return .none }
    return try await start()
  }

  private func isNeeded(force: Bool, listing: [StorageObject]) async throws(SyncError) -> Bool {
    if force { return true }
    let entries = try await entries()
    let now = context.millis
    let sizes = Dictionary(listing.map { ($0.key, $0.size) }, uniquingKeysWith: max)
    let old = entries.filter { !$0.isBase && $0.isLive && Self.age(of: $0.uploaded, now: now) >= context.configuration.compactionAge.milliseconds }
    let bytes = old.reduce(0) { total, entry in total + (segmentKey(entry).flatMap { sizes[$0] } ?? 0) }
    guard old.count >= context.configuration.compactionFiles || bytes >= context.configuration.compactionBytes else { return false }
    guard let base = Self.currentBase(entries) else { return true }
    return Self.age(of: base.uploaded, now: now) >= context.configuration.compactionInterval.milliseconds
  }

  /// A time recorded while the device clock ran ahead of trusted time counts as now.
  private static func age(of recorded: Int64, now: Int64) -> Int64 {
    now - min(recorded, now)
  }

  /// Continues a row of an earlier call only when the own writes still seal to the same names; otherwise the row is dropped and its announced base kept for cleanup, because another copy of this database may have completed it.
  private func resume() async throws(SyncError) -> SyncCompactionStage {
    guard let row = try await read({ try SyncCompactionTable.load($0) }) else { return .none }
    guard row.replica == context.replica else {
      try await write { try SyncCompactionTable.clear($0) }
      return .none
    }
    switch try await seal() {
    case .postponed:
      return .postponed
    case .sealed(let base) where base.point == row.point && base.parts.count == row.parts:
      try await upload(base)
      return .completed(base.point)
    case .empty, .sealed:
      try await write { try SyncCompactionTable.clear($0) }
      return .none
    }
  }

  /// A point recorded before and never completed is not put again: a late delete of its earlier attempt could remove a part put now.
  private func start() async throws(SyncError) -> SyncCompactionStage {
    let sealed: SyncSealedBase
    switch try await seal() {
    case .postponed: return .postponed
    case .empty: return .none
    case .sealed(let base): sealed = base
    }
    let entries = try await entries()
    if let current = Self.currentBase(entries), current.point == sealed.point { return .none }
    guard !entries.contains(where: { $0.isBase && $0.point == sealed.point }) else { return .postponed }
    let replica = context.replica
    let row = SyncCompactionRow(replica: replica, point: sealed.point, parts: sealed.parts.count)
    let millis = context.millis
    try await write { db in
      try ReplicaHistory.announceBase(sealed.point, parts: row.parts, replica: replica, at: millis, in: db)
      try SyncCompactionTable.save(row, at: millis, in: db)
    }
    try await context.checkpoint(.announced)
    try await upload(sealed)
    return .completed(sealed.point)
  }

  /// A part's name is a keyed hash of the base's content, so a part already there under that name is this part.
  private func upload(_ base: SyncSealedBase) async throws(SyncError) {
    let condition: PutCondition = context.provider.capabilities.supportsPutIfAbsent ? .ifAbsent : .overwrite
    for part in base.parts {
      do {
        let receipt = try await context.provider.put(part.key, data: part.data, condition: condition)
        if let serverTime = receipt.serverTime { context.trustedClock.record(serverDate: serverTime) }
      } catch {
        guard case .alreadyExists = error else { throw .storage(error) }
      }
      try await context.checkpoint(.partPut)
    }
    try await context.checkpoint(.allPartsPut)
    let replica = context.replica
    let millis = context.millis
    let parts = base.parts.count
    try await write { db in
      try ReplicaHistory.recordBase(base.point, parts: parts, replica: replica, at: millis, in: db)
      try SyncCompactionTable.clear(db)
    }
    try await context.checkpoint(.completed)
    try await context.putManifest(context.key, replica)
    try await context.checkpoint(.manifestPut)
  }

  /// Only changes already uploaded as segments may enter a base: an unsent change has not passed the clock check.
  private func seal() async throws(SyncError) -> SyncSealResult {
    let replica = context.replica
    let head = try await read { try ReplicaHistory.head(of: replica, in: $0) }
    let snapshot: OwnSnapshot
    do {
      snapshot = try await context.store.ownSnapshot()
    } catch {
      throw SyncError(converting: error)
    }
    guard snapshot.replica == replica else { throw .replicaChanged }
    guard snapshot.upTo == (head?.last ?? 0) else { return .postponed }
    guard let head, !snapshot.lines.isEmpty else { return .empty }
    try refuseUnstorable(snapshot.lines)
    guard let header = BaseHeader(replica: replica, upTo: snapshot.upTo, through: head, schema: snapshot.schema), let file = BaseFile(header: header, lines: snapshot.lines)
    else { throw .corruptState("the own writes do not form a base") }
    let parts = try sealParts(file)
    guard let tag = parts.first?.tag else { throw .corruptState("a sealed base has no parts") }
    return .sealed(SyncSealedBase(point: StreamPoint(last: snapshot.upTo, tag: tag), parts: parts))
  }

  /// An opaque line or a kind this registry does not declare reaches the own writes only by adoption, from a file a newer app already stored with this provider.
  private func refuseUnstorable(_ lines: [Data]) throws(SyncError) {
    let policy = context.provider.capabilities.classPolicy
    var admitted: Set<EntityKind> = []
    for line in lines {
      guard let json = try? CanonicalJSON.decode(line), let record = try? ChangeRecord(json: json), admitted.insert(record.entity).inserted else { continue }
      guard let schema = context.store.registry[record.entity] else { continue }
      guard policy.admits(schema.syncClass) else { throw .syncClassRefused(kind: record.entity, syncClass: schema.syncClass) }
    }
  }

  private func sealParts(_ file: BaseFile) throws(SyncError) -> [SealedFile] {
    try SyncBaseSealer.sealParts(
      file, vault: context.vault, key: context.key, partBytes: context.configuration.basePartBytes, limit: context.provider.capabilities.maxObjectBytes)
  }

  /// Deletes only when the base completed last is fully listed, and only what it covers, by recorded names; each file is deleted before it is marked, so a crash repeats a delete rather than leaking a file.
  private func cleanUp() async throws(SyncError) -> (segments: Int, bases: Int) {
    let replica = context.replica
    let (entries, row) = try await read { db in (try ReplicaHistory.entries(of: replica, in: db), try SyncCompactionTable.load(db)) }
    guard let current = Self.currentBase(entries), let currentKeys = baseKeys(current) else { return (0, 0) }
    let listing = try await list()
    let listed = Set(listing.map(\.key))
    guard currentKeys.allSatisfy(listed.contains) else { return (0, 0) }
    let verdict = try await lifecycleCall { () async throws(ReplicaLifecycleError) in try await context.lifecycle.selfCheck(listing: listing.map(\.key)) }
    guard context.store.replica == replica else { throw .replicaChanged }
    guard verdict == .pass else { return (0, 0) }
    let inProgress = row.flatMap { $0.replica == replica ? $0.point : nil }
    var bases = 0
    for entry in entries where entry.isBase && entry.isLive && entry.point != current.point && entry.point != inProgress && Self.isSuperseded(entry, by: current) {
      guard let keys = baseKeys(entry) else { continue }
      try await delete(keys)
      try await mark([entry.point], isBase: true)
      bases += 1
    }
    let now = context.millis
    let covered = entries.compactMap { entry -> (point: StreamPoint, key: ObjectKey)? in
      guard !entry.isBase, entry.isLive, entry.point.last <= current.point.last, let key = segmentKey(entry) else { return nil }
      guard Self.age(of: entry.uploaded, now: now) >= context.configuration.compactionAge.milliseconds else { return nil }
      return (entry.point, key)
    }
    var segments = 0
    for start in stride(from: 0, to: covered.count, by: Self.deleteBatch) {
      let batch = covered[start..<min(start + Self.deleteBatch, covered.count)]
      try await delete(batch.map(\.key))
      try await mark(batch.map(\.point), isBase: false)
      segments += batch.count
    }
    return (segments, bases)
  }

  /// Adopted lines make a new base at the same `upTo`, so there only a base completed earlier is known to be contained in the current one.
  private static func isSuperseded(_ entry: SyncUploadEntry, by current: SyncUploadEntry) -> Bool {
    guard entry.point.last == current.point.last else { return entry.point.last < current.point.last }
    guard let completed = entry.completed, let currentCompleted = current.completed else { return false }
    return completed < currentCompleted
  }

  private func baseKeys(_ entry: SyncUploadEntry) -> [ObjectKey]? {
    guard entry.isBase, let parts = entry.parts, VaultPath.isPart(1, of: parts) else { return nil }
    return (1...parts).map { VaultPath.basePart(context.replica, upTo: entry.point.last, tag: entry.point.tag, part: $0, parts: parts) }
  }

  private func segmentKey(_ entry: SyncUploadEntry) -> ObjectKey? {
    guard !entry.isBase, let first = entry.first, first >= 1, first <= entry.point.last, entry.point.last <= VaultPath.maximumSequence else { return nil }
    return VaultPath.segment(context.replica, first: first, last: entry.point.last, tag: entry.point.tag)
  }

  private static func currentBase(_ entries: [SyncUploadEntry]) -> SyncUploadEntry? {
    entries.filter { $0.isCompleteBase && $0.isLive }.max { ($0.completed ?? 0) < ($1.completed ?? 0) }
  }

  private func entries() async throws(SyncError) -> [SyncUploadEntry] {
    let replica = context.replica
    return try await read { try ReplicaHistory.entries(of: replica, in: $0) }
  }

  private func delete(_ keys: [ObjectKey]) async throws(SyncError) {
    guard !keys.isEmpty else { return }
    do {
      try await context.provider.delete(keys)
    } catch {
      throw .storage(error)
    }
    try await context.checkpoint(.deleted)
  }

  private func mark(_ points: [StreamPoint], isBase: Bool) async throws(SyncError) {
    let replica = context.replica
    let millis = context.millis
    try await write { db in
      for point in points { try ReplicaHistory.markDeleted(point, isBase: isBase, replica: replica, at: millis, in: db) }
    }
    try await context.checkpoint(.marked)
  }

  private func list() async throws(SyncError) -> [StorageObject] {
    do {
      return try await context.provider.listAll(prefix: VaultPath.replicaPrefix(context.replica))
    } catch {
      throw .storage(error)
    }
  }

  private func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws(SyncError) -> T {
    do {
      return try await context.store.read { try body($0.database) }
    } catch {
      throw SyncError(converting: error)
    }
  }

  private func write(_ body: @Sendable (Database) throws -> Void) async throws(SyncError) {
    let replica = context.replica
    do {
      try await context.store.write { transaction in
        try SyncReplicaGuard.require(replica, in: transaction.database)
        try body(transaction.database)
      }
    } catch {
      throw SyncError(converting: error)
    }
  }

  private func lifecycleCall<T>(_ body: () async throws(ReplicaLifecycleError) -> T) async throws(SyncError) -> T {
    do {
      return try await body()
    } catch {
      throw SyncError(converting: error)
    }
  }
}

enum SyncBaseSealer {
  /// Shrinks the part payload until every sealed part fits the provider, so a base that cannot fit is refused before anything is announced or put.
  static func sealParts(_ file: BaseFile, vault: VaultID, key: VaultKey, partBytes: Int, limit: Int) throws(SyncError) -> [SealedFile] {
    var budget = min(max(partBytes, 1), BaseCodec.maximumPartPayloadBytes)
    while true {
      let parts: [SealedFile]
      do {
        parts = try BaseCodec.seal(file, vault: vault, with: key, partPayloadBytes: budget)
      } catch {
        switch error {
        case .lineTooLarge, .payloadTooLarge: throw .baseTooLarge(limit: min(budget, limit))
        default: throw .codec(error)
        }
      }
      let largest = parts.map(\.data.count).max() ?? 0
      guard largest > limit else { return parts }
      let next = min(budget - (largest - limit), budget - 1, budget - budget / 16)
      guard next >= 1 else { throw .baseTooLarge(limit: limit) }
      budget = next
    }
  }
}

extension Duration {
  var milliseconds: Int64 {
    let (seconds, attoseconds) = components
    return seconds.multipliedReportingOverflow(by: 1_000).overflow ? .max : seconds * 1_000 + attoseconds / 1_000_000_000_000_000
  }
}
