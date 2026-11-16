import Foundation
import GRDB
import ShadowCore
import ShadowStore

struct SyncListedSegment: Sendable {
  let key: ObjectKey
  let first: Int64
  let point: StreamPoint
  let size: Int
}

struct SyncListedBase: Sendable {
  let point: StreamPoint
  let parts: Int
  var keys: [Int: ObjectKey] = [:]
  var size = 0

  var missing: [Int] { (1...parts).filter { keys[$0] == nil } }
}

struct SyncListedReplica: Sendable {
  var segments: [SyncListedSegment] = []
  var bases: [StreamPoint: SyncListedBase] = [:]
}

enum SyncListing {
  static func group(_ objects: [StorageObject], excluding own: ReplicaID) -> [ReplicaID: SyncListedReplica] {
    var replicas: [ReplicaID: SyncListedReplica] = [:]
    for object in objects {
      switch VaultPath.classify(object.key) {
      case .segment(let replica, let first, let last, let tag) where replica != own:
        let segment = SyncListedSegment(key: object.key, first: first, point: StreamPoint(last: last, tag: tag), size: object.size)
        replicas[replica, default: SyncListedReplica()].segments.append(segment)
      case .basePart(let replica, let upTo, let tag, let part, let parts) where replica != own:
        let point = StreamPoint(last: upTo, tag: tag)
        var base = replicas[replica]?.bases[point] ?? SyncListedBase(point: point, parts: parts)
        guard base.parts == parts, base.keys[part] == nil else { continue }
        base.keys[part] = object.key
        base.size += object.size
        replicas[replica, default: SyncListedReplica()].bases[point] = base
      default:
        continue
      }
    }
    for replica in replicas.keys { replicas[replica]?.segments.sort { ($0.first, $0.point.tag) < ($1.first, $1.point.tag) } }
    return replicas
  }
}

struct SyncDownloadContext: Sendable {
  let store: VaultStore
  let provider: any StorageProvider
  let vault: VaultID
  let ring: KeyRing
  let configuration: SyncConfiguration
  let limit: HLCTimestamp
  let wallClock: @Sendable () -> Date
  let checkpoint: @Sendable (SyncDownloadStep) throws(SyncError) -> Void

  var millis: Int64 {
    max(0, Int64((wallClock().timeIntervalSince1970 * 1_000).rounded(.down)))
  }
}

enum SyncPassResult: Sendable, Equatable {
  case finished
  case collision(found: ReplicaID)
}

/// One `download()` call; the caches outlive a re-mint within the call so no file is fetched twice to fail twice.
struct SyncDownloadSession {
  static let unlistedCallsKept = 20

  private enum Step {
    case applied
    case held
    case collision(ReplicaID)
  }

  private let context: SyncDownloadContext
  private let previous: [SyncFileID: SyncHeldFile]
  private(set) var unsupported: [SyncFileID: Int]
  private var appliedFiles: [SyncFileID] = []
  private var reminted = false
  private var held: [SyncFileID: SyncHeldFile] = [:]
  private var blocked: [SyncFileID: SyncHeldFile] = [:]
  private var headers: [SyncFileID: SegmentHeader] = [:]
  private var vanished: Set<SyncFileID> = []
  private var forcing: Set<SyncFileID> = []
  private var listed: Set<SyncFileID> = []
  private var files: [ReplicaID: SyncAppliedFiles] = [:]
  private var own: ReplicaID
  private var head: StreamPoint?

  /// `unsupported` maps files this engine instance found in a format it cannot read to their listed size; an app update starts a new instance.
  init(context: SyncDownloadContext, previous: [SyncFileID: SyncHeldFile], unsupported: [SyncFileID: Int]) {
    self.context = context
    self.previous = previous
    self.unsupported = unsupported
    own = context.store.replica
  }

  func outcome(postponed: Bool) -> SyncDownloadOutcome {
    var missingKeys: [KeyID: Set<ReplicaID>] = [:]
    for file in held.values {
      guard case .missingKey(let key) = file.reason else { continue }
      missingKeys[key, default: []].insert(file.id.replica)
    }
    return SyncDownloadOutcome(applied: appliedFiles, held: held.mapValues(\.reason), missingKeys: missingKeys, reminted: reminted, postponed: postponed)
  }

  /// A row outlives its file in the listing for a while, so a stale listing does not reset a rejected file's count.
  var retainedRows: [SyncHeldFile] {
    let applied = Set(appliedFiles)
    var rows = held.values.map { file in
      var row = file
      row.waits = waits(file)
      row.unlisted = 0
      return row
    }
    for (id, row) in previous where held[id] == nil && !applied.contains(id) {
      var kept = row
      kept.unlisted = listed.contains(id) ? 0 : row.unlisted + 1
      if kept.unlisted <= Self.unlistedCallsKept { rows.append(kept) }
    }
    return rows
  }

  mutating func noteRemint() {
    reminted = true
  }

  mutating func run(_ listing: [ReplicaID: SyncListedReplica]) async throws(SyncError) -> SyncPassResult {
    own = context.store.replica
    held = [:]
    listed = Set(
      listing.flatMap { replica, files in
        files.segments.map { SyncFileID(replica: replica, kind: .segment, point: $0.point) } + files.bases.keys.map { SyncFileID(replica: replica, kind: .base, point: $0) }
      })
    let replica = own
    (files, head) = try await read { db in (try SyncAppliedTable.load(db), try ReplicaHistory.head(of: replica, in: db)) }
    let order = listing.keys.sorted()
    while true {
      var progressed = false
      for replica in order {
        guard let listed = listing[replica] else { continue }
        switch try await advance(replica, listed) {
        case .collision(let found): return .collision(found: found)
        case .applied: progressed = true
        case .held: break
        }
      }
      if progressed { continue }
      let overdue = held.values.filter { !forcing.contains($0.id) && waits($0) >= max(context.configuration.dependencyWaitCalls, 1) }
      guard !overdue.isEmpty else { return .finished }
      forcing.formUnion(overdue.map(\.id))
    }
  }

  /// Consecutive calls, this one included, that the file has waited for the same replica.
  private func waits(_ file: SyncHeldFile) -> Int {
    guard case .waitingForDependency(let replica) = file.reason else { return 0 }
    guard let row = previous[file.id], row.reason == .waitingForDependency(replica) else { return 1 }
    return row.waits + 1
  }

  private mutating func advance(_ replica: ReplicaID, _ listed: SyncListedReplica) async throws(SyncError) -> Step {
    var progressed = false
    switch try await applyBases(of: replica, listed) {
    case .collision(let found): return .collision(found)
    case .applied: progressed = true
    case .held: break
    }
    while true {
      var stepped = false
      for segment in listed.segments where !(files[replica]?.segments.contains(segment.point) ?? false) {
        switch try await consider(segment, of: replica) {
        case .collision(let found): return .collision(found)
        case .applied: stepped = true
        case .held: break
        }
      }
      guard stepped else { break }
      progressed = true
    }
    return progressed ? .applied : .held
  }

  /// Every intact base is applied once, whatever else of its replica was applied: a base can hold records no listed segment does.
  private mutating func applyBases(of replica: ReplicaID, _ listed: SyncListedReplica) async throws(SyncError) -> Step {
    var progressed = false
    for base in listed.bases.values.sorted(by: { $0.point < $1.point }) where !(files[replica]?.bases.contains(base.point) ?? false) {
      let id = SyncFileID(replica: replica, kind: .base, point: base.point)
      guard !vanished.contains(id), !isBlocked(id, size: base.size) else { continue }
      let missing = base.missing
      guard missing.isEmpty else {
        hold(id, size: base.size, .incompleteBase(missing: missing))
        continue
      }
      guard let file = try await fetchBase(base, id: id) else { continue }
      switch try await apply(file.lines, id: id, first: nil, size: base.size) {
      case .applied: progressed = true
      case .collision(let found): return .collision(found)
      case .held: continue
      }
    }
    return progressed ? .applied : .held
  }

  private mutating func consider(_ segment: SyncListedSegment, of replica: ReplicaID) async throws(SyncError) -> Step {
    let id = SyncFileID(replica: replica, kind: .segment, point: segment.point)
    guard files[replica, default: SyncAppliedFiles()].maySatisfyPredecessor(ofFirst: segment.first) else {
      hold(id, size: segment.size, .waitingForPredecessor)
      return .held
    }
    guard !vanished.contains(id), !isBlocked(id, size: segment.size) else { return .held }
    if let header = headers[id], let reason = unreadiness(of: header, id: id) {
      hold(id, size: segment.size, reason)
      return .held
    }
    guard let file = try await fetchSegment(segment, id: id) else { return .held }
    headers[id] = file.header
    if let reason = unreadiness(of: file.header, id: id) {
      hold(id, size: segment.size, reason)
      return .held
    }
    return try await apply(file.lines, id: id, first: segment.first, size: segment.size)
  }

  private func unreadiness(of header: SegmentHeader, id: SyncFileID) -> SyncHoldReason? {
    if let previous = header.previous, !(files[id.replica]?.satisfies(previous) ?? false) { return .waitingForPredecessor }
    guard !forcing.contains(id) else { return nil }
    for (dependency, point) in header.dependencies.sorted(by: { $0.key < $1.key }) {
      let satisfied = dependency == own ? (head.map { $0.last >= point.last } ?? false) : (files[dependency]?.satisfies(point) ?? false)
      if !satisfied { return .waitingForDependency(dependency) }
    }
    return nil
  }

  private mutating func fetchSegment(_ segment: SyncListedSegment, id: SyncFileID) async throws(SyncError) -> SegmentFile? {
    guard let data = try await fetch(segment.key, id: id, size: segment.size) else { return nil }
    do {
      return try SegmentCodec.open(data, at: segment.key, vault: context.vault) { context.ring.key($0) }
    } catch {
      try await fail(id, size: segment.size, Self.reason(for: error))
      return nil
    }
  }

  private mutating func fetchBase(_ base: SyncListedBase, id: SyncFileID) async throws(SyncError) -> BaseFile? {
    var parts: [BasePart] = []
    for (number, key) in base.keys.sorted(by: { $0.key < $1.key }) {
      guard number == parts.count + 1, let data = try await fetch(key, id: id, size: base.size) else { return nil }
      do {
        parts.append(try BaseCodec.openPart(data, at: key, vault: context.vault) { context.ring.key($0) })
      } catch {
        try await fail(id, size: base.size, Self.reason(for: error))
        return nil
      }
    }
    do {
      return try BaseCodec.assemble(parts) { context.ring.key($0) }
    } catch {
      try await fail(id, size: base.size, Self.reason(for: error))
      return nil
    }
  }

  /// The key id comes from the unauthenticated header: a forged one only holds the file, it never opens it.
  private mutating func fetch(_ key: ObjectKey, id: SyncFileID, size: Int) async throws(SyncError) -> Data? {
    let data: Data
    do {
      data = try await context.provider.get(key)
    } catch {
      switch error {
      case .notFound:
        vanished.insert(id)
        return nil
      case .tooLarge, .keyConflict, .underlying, .alreadyExists:
        block(id, size: size, .unavailable)
        return nil
      case .unavailable, .rateLimited, .quotaExceeded, .unauthenticated:
        throw .storage(error)
      }
    }
    let keyID: KeyID
    do {
      keyID = try VaultFile.header(of: data).keyID
    } catch {
      try await fail(id, size: size, Self.reason(for: .file(error)))
      return nil
    }
    guard context.ring.key(keyID) != nil else {
      block(id, size: size, .missingKey(keyID))
      return nil
    }
    return data
  }

  private mutating func apply(_ lines: [Data], id: SyncFileID, first: Int64?, size: Int) async throws(SyncError) -> Step {
    let millis = context.millis
    do {
      _ = try await context.store.applyRemote(lines, notAfter: context.limit) { db in
        try SyncAppliedTable.record(id.point, first: first, isBase: id.kind == .base, replica: id.replica, at: millis, in: db)
        try SyncHeldTable.remove(id, in: db)
      }
    } catch {
      if case .replicaCollision = error { return .collision(id.replica) }
      guard case .clockAhead(let clock) = error else { throw SyncError(converting: error) }
      block(id, size: size, .clockAhead, clock: clock)
      return .held
    }
    try context.checkpoint(.applied)
    files[id.replica, default: SyncAppliedFiles()].insert(id.point, kind: id.kind)
    held[id] = nil
    headers[id] = nil
    appliedFiles.append(id)
    return .applied
  }

  /// A rejected file, a key the ring still lacks, a clock still beyond the limit and a format this instance cannot read are known without fetching again.
  private mutating func isBlocked(_ id: SyncFileID, size: Int) -> Bool {
    if let file = blocked[id] {
      held[id] = file
      return true
    }
    if unsupported[id] == size {
      block(id, size: size, .unsupported)
      return true
    }
    guard let row = previous[id], row.size == size else { return false }
    let stillBlocked: Bool
    switch row.reason {
    case .rejected: stillBlocked = true
    case .missingKey(let key): stillBlocked = context.ring.key(key) == nil
    case .clockAhead: stillBlocked = row.clock.map { $0 > context.limit } ?? false
    default: stillBlocked = false
    }
    guard stillBlocked else { return false }
    block(id, size: size, row.reason, clock: row.clock)
    return true
  }

  private mutating func hold(_ id: SyncFileID, size: Int, _ reason: SyncHoldReason, clock: HLCTimestamp? = nil) {
    held[id] = SyncHeldFile(id: id, size: size, reason: reason, clock: clock, attempts: attempts(id, size: size), waits: 0, unlisted: 0)
  }

  private mutating func block(_ id: SyncFileID, size: Int, _ reason: SyncHoldReason, clock: HLCTimestamp? = nil) {
    hold(id, size: size, reason, clock: clock)
    blocked[id] = held[id]
  }

  /// Counted once per call and saved at once, so a call that fails later still counts towards rejection.
  private mutating func fail(_ id: SyncFileID, size: Int, _ reason: SyncHoldReason) async throws(SyncError) {
    if reason == .unsupported { unsupported[id] = size }
    guard reason == .unauthenticated || reason == .malformed else {
      block(id, size: size, reason)
      return
    }
    let count = attempts(id, size: size) + 1
    let file = SyncHeldFile(
      id: id, size: size, reason: count >= context.configuration.unreadableFileAttempts ? .rejected : reason, clock: nil, attempts: count, waits: 0, unlisted: 0)
    held[id] = file
    blocked[id] = file
    try await write { try SyncHeldTable.save(file, in: $0) }
  }

  private func attempts(_ id: SyncFileID, size: Int) -> Int {
    guard let row = previous[id], row.size == size else { return 0 }
    return row.attempts
  }

  /// A newer app may write a format this one cannot read; that must never count towards rejection.
  private static func reason(for error: VaultCodecError) -> SyncHoldReason {
    switch error {
    case .file(.keyUnavailable(let key)): .missingKey(key)
    case .file(.unsupportedVersion), .file(.unsupportedFlags), .unsupportedFormat, .unsupportedCodec: .unsupported
    case .file: .unauthenticated
    default: .malformed
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
    do {
      try await context.store.write { try body($0.database) }
    } catch {
      throw SyncError(converting: error)
    }
  }
}
