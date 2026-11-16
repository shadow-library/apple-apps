import Foundation
import GRDB
import ShadowCore
import ShadowStore

enum SyncUploadStep: Sendable, Equatable, CaseIterable {
  case outboxSaved
  case putDone
  case recorded
  case dropped
}

struct SyncPendingChange: Sendable {
  let sequence: Int64
  let line: Data
  let record: ChangeRecord
}

public actor SyncEngine {
  static let maximumRemintsPerUpload = 3
  static let highestReplica = ReplicaID(UUID(uuid: (0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)))

  private enum Readiness {
    case notStarted
    case started
    case resumeRequired
  }

  private let store: VaultStore
  private let provider: any StorageProvider
  private let vault: VaultID
  private let ring: KeyRing
  private let lifecycle: ReplicaLifecycle
  private let trustedClock: TrustedClock
  private let configuration: SyncConfiguration
  private let wallClock: @Sendable () -> Date
  private let checkpoint: @Sendable (SyncUploadStep) throws(SyncError) -> Void
  private let downloadCheckpoint: @Sendable (SyncDownloadStep) throws(SyncError) -> Void
  private let publicFloor: @Sendable () async throws(SyncError) -> HLCTimestamp?
  private var readiness = Readiness.notStarted
  private var unsupportedFiles: [SyncFileID: Int] = [:]
  private var isBusy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public private(set) var deviceClock = SyncDeviceClock.unchecked

  /// Open `store` with `SyncEngine.wallClock(preferring:device:)` over this `trustedClock`, or uploads stop with `storeClockUntrusted`.
  public init(
    store: VaultStore,
    provider: any StorageProvider,
    vault: VaultID,
    ring: KeyRing,
    lifecycle: ReplicaLifecycle,
    trustedClock: TrustedClock,
    configuration: SyncConfiguration = .init(),
    wallClock: @escaping @Sendable () -> Date = { Date() }
  ) {
    let publicFloor: @Sendable () async throws(SyncError) -> HLCTimestamp? = { () async throws(SyncError) in
      do throws(StoreError) {
        return try await store.publicClockFloor()
      } catch {
        throw SyncError(converting: error)
      }
    }
    self.init(
      store: store, provider: provider, vault: vault, ring: ring, lifecycle: lifecycle, trustedClock: trustedClock, configuration: configuration, wallClock: wallClock,
      publicFloor: publicFloor
    ) { _ throws(SyncError) in }
  }

  init(
    store: VaultStore,
    provider: any StorageProvider,
    vault: VaultID,
    ring: KeyRing,
    lifecycle: ReplicaLifecycle,
    trustedClock: TrustedClock,
    configuration: SyncConfiguration,
    wallClock: @escaping @Sendable () -> Date,
    publicFloor: @escaping @Sendable () async throws(SyncError) -> HLCTimestamp?,
    checkpoint: @escaping @Sendable (SyncUploadStep) throws(SyncError) -> Void,
    downloadCheckpoint: @escaping @Sendable (SyncDownloadStep) throws(SyncError) -> Void = { _ throws(SyncError) in }
  ) {
    self.store = store
    self.provider = provider
    self.vault = vault
    self.ring = ring
    self.lifecycle = lifecycle
    self.trustedClock = trustedClock
    self.configuration = configuration
    self.wallClock = wallClock
    self.checkpoint = checkpoint
    self.downloadCheckpoint = downloadCheckpoint
    self.publicFloor = publicFloor
  }

  public static var migrations: [StoreMigration] {
    ReplicaLifecycle.migrations + [SyncEngineSchema.migration, SyncEngineSchema.heldMigration]
  }

  public static func wallClock(preferring trustedClock: TrustedClock, device: @escaping @Sendable () -> Date = { Date() }) -> @Sendable () -> Date {
    {
      guard case .estimate(let trusted) = trustedClock.now() else { return device() }
      return trusted
    }
  }

  public func start() async throws(SyncError) -> ReplicaBootstrap {
    await acquire()
    defer { release() }
    return try await bootstrap()
  }

  public func upload() async throws(SyncError) -> SyncUploadOutcome {
    await acquire()
    defer { release() }
    return try await performUpload()
  }

  public func download() async throws(SyncError) -> SyncDownloadOutcome {
    await acquire()
    defer { release() }
    return try await performDownload()
  }

  public func sync() async throws(SyncError) -> (download: SyncDownloadOutcome, upload: SyncUploadOutcome) {
    await acquire()
    defer { release() }
    let download = try await performDownload()
    return (download, try await performUpload())
  }

  private func performUpload() async throws(SyncError) -> SyncUploadOutcome {
    guard try await resume() else { return .postponed }
    try await refuseNewerSchema()
    try await repairDroppedChanges()
    var uploaded = try await finishInFlight().map { [$0] } ?? []
    var remints = 0
    var corrected = false
    while true {
      let floor = try await raisedFloors().key
      guard let key = try await writingKey(floor: floor) else { return .awaitingKey(floor: floor) }
      switch try await selfCheck() {
      case .postpone:
        return .postponed
      case .remint(let reason):
        guard try await remint(reason: reason, mode: .keepState, count: &remints) else { return .postponed }
        continue
      case .pass:
        break
      }
      if provider.capabilities.reportsServerTime { try await putManifest(sealedWith: key) }
      if try await isClockCorrectionNeeded(), !corrected {
        corrected = true
        guard try await remint(reason: .clockCorrected, mode: .rebuild, count: &remints) else { return .postponed }
        continue
      }
      uploaded += try await sendPending(sealedWith: key)
      return uploaded.isEmpty ? .nothingToUpload : .uploaded(uploaded)
    }
  }

  public func minimumSchema() async throws(SyncError) -> Int? {
    try await raisedFloors().schema
  }

  public func appliedPoints() async throws(SyncError) -> [ReplicaID: StreamPoint] {
    let replica = store.replica
    return try await read { try SyncAppliedTable.points(excluding: replica, in: $0.database) }
  }

  private func performDownload() async throws(SyncError) -> SyncDownloadOutcome {
    guard try await resume() else { return SyncDownloadOutcome(applied: [], held: [:], missingKeys: [:], reminted: false, postponed: true) }
    try await refuseNewerSchema()
    do {
      try ring.refresh()
    } catch {
      throw .keyRing(error)
    }
    let previous = try await read { try SyncHeldTable.load($0.database) }
    let context = SyncDownloadContext(
      store: store, provider: provider, vault: vault, ring: ring, configuration: configuration, limit: try readerLimit(), wallClock: wallClock, checkpoint: downloadCheckpoint)
    var session = SyncDownloadSession(context: context, previous: previous, unsupported: unsupportedFiles)
    defer { unsupportedFiles = session.unsupported }
    var remints = 0
    var postponed = false
    while case .collision(let found) = try await session.run(try await listForeignFiles()) {
      guard try await remint(reason: .replicaCollision(found: found), mode: .keepState, count: &remints) else {
        postponed = true
        break
      }
      session.noteRemint()
    }
    let rows = session.retainedRows
    try await write { try SyncHeldTable.replace(with: rows, in: $0.database) }
    if !postponed { _ = try await raisedFloors() }
    return session.outcome(postponed: postponed)
  }

  /// Returns false when an interrupted re-mint cannot resume because the device marker cannot be read.
  private func resume() async throws(SyncError) -> Bool {
    switch readiness {
    case .notStarted:
      throw .notStarted
    case .resumeRequired:
      do {
        _ = try await bootstrap()
      } catch {
        guard case .lifecycle(.markerUnavailable) = error else { throw error }
        return false
      }
      return true
    case .started:
      return true
    }
  }

  private func refuseNewerSchema() async throws(SyncError) {
    guard let minimum = try await raisedFloors().schema, minimum > store.registry.version else { return }
    throw .appUpdateRequired(minimumSchema: minimum, current: store.registry.version)
  }

  private func listForeignFiles() async throws(SyncError) -> [ReplicaID: SyncListedReplica] {
    do {
      return SyncListing.group(try await provider.listAll(prefix: VaultPath.replicasPrefix), excluding: store.replica)
    } catch {
      throw .storage(error)
    }
  }

  private func readerLimit() throws(SyncError) -> HLCTimestamp {
    let now: Date
    if case .estimate(let trusted) = trustedClock.now() {
      now = trusted
    } else {
      now = store.wallClock()
    }
    let millis = ((now.timeIntervalSince1970 + configuration.futureLimit.timeInterval) * 1_000).rounded(.down)
    let clamped = Int64(min(max(millis, 0), Double(HLCTimestamp.maxWallMillis)))
    guard let limit = HLCTimestamp(wallMillis: clamped, counter: .max, replica: Self.highestReplica) else { throw .corruptState("the reader limit is out of range") }
    return limit
  }

  private func bootstrap() async throws(SyncError) -> ReplicaBootstrap {
    let result: ReplicaBootstrap
    do {
      result = try await lifecycle.bootstrap()
    } catch {
      throw SyncError(converting: error)
    }
    readiness = .started
    return result
  }

  private func repairDroppedChanges() async throws(SyncError) {
    let replica = store.replica
    guard let head = try await read({ try ReplicaHistory.head(of: replica, in: $0.database) }) else { return }
    guard let first = try await storeCall({ () async throws(StoreError) in try await store.pendingChanges(limit: 1).first }), first.sequence <= head.last else { return }
    try await storeCall { () async throws(StoreError) in try await store.dropChanges(through: head.last) }
  }

  /// A saved upload of an earlier id was re-logged by the re-mint that retired that id, so it is dropped rather than put under a prefix this database left.
  private func finishInFlight() async throws(SyncError) -> StreamPoint? {
    guard let entry = try await read({ try SyncOutbox.load($0.database) }) else { return nil }
    guard entry.replica == store.replica else {
      try await write { try SyncOutbox.clear($0.database) }
      return nil
    }
    return try await finish(entry)
  }

  private func finish(_ entry: SyncOutboxEntry) async throws(SyncError) -> StreamPoint {
    let condition: PutCondition = provider.capabilities.supportsPutIfAbsent ? .ifAbsent : .overwrite
    do {
      let receipt = try await provider.put(entry.key, data: entry.data, condition: condition)
      if let serverTime = receipt.serverTime { trustedClock.record(serverDate: serverTime) }
    } catch {
      guard case .alreadyExists = error else { throw .storage(error) }
    }
    try checkpoint(.putDone)
    let millis = millis
    try await write { transaction in
      try ReplicaHistory.recordSegment(entry.point, first: entry.first, replica: entry.replica, at: millis, in: transaction.database)
      try SyncOutbox.clear(transaction.database)
    }
    try checkpoint(.recorded)
    try await storeCall { () async throws(StoreError) in try await store.dropChanges(through: entry.last) }
    try checkpoint(.dropped)
    return entry.point
  }

  private func writingKey(floor: KeyID?) async throws(SyncError) -> VaultKey? {
    do {
      try ring.refresh()
    } catch {
      throw .keyRing(error)
    }
    return ring.writingKey(floor: floor)
  }

  /// A rebuild clears the directory's floor records until the vault is joined again, so the engine keeps the highest it has read.
  private func raisedFloors() async throws(SyncError) -> SyncFloors {
    let directory = try await lifecycleCall { () async throws(ReplicaLifecycleError) in try await lifecycle.directory() }
    let read = SyncFloors(key: directory.keyFloor, schema: directory.minimumSchema)
    return try await write { try SyncFloorTable.raise(to: read, in: $0.database) }
  }

  private func putManifest(sealedWith key: VaultKey) async throws(SyncError) {
    let applied = try await appliedPoints()
    let manifest = try await lifecycleCall { () async throws(ReplicaLifecycleError) in try await lifecycle.manifest(applied: applied) }
    let sealed: (key: ObjectKey, data: Data)
    do {
      sealed = try ReplicaManifestCodec.seal(manifest, vault: vault, with: key)
    } catch {
      throw .replicaFile(error)
    }
    do {
      let receipt = try await provider.put(sealed.key, data: sealed.data, condition: .overwrite)
      if let serverTime = receipt.serverTime { trustedClock.record(serverDate: serverTime) }
    } catch {
      throw .storage(error)
    }
  }

  private func selfCheck() async throws(SyncError) -> ReplicaSelfCheckVerdict {
    let listing: [StorageObject]
    do {
      listing = try await provider.listAll(prefix: VaultPath.replicaPrefix(store.replica))
    } catch {
      throw .storage(error)
    }
    return try await lifecycleCall { () async throws(ReplicaLifecycleError) in try await lifecycle.selfCheck(listing: listing.map(\.key)) }
  }

  /// Returns false when the device marker cannot be read; the lifecycle checks it before changing anything.
  private func remint(reason: RemintReason, mode: RemintMode, count: inout Int) async throws(SyncError) -> Bool {
    guard count < Self.maximumRemintsPerUpload else { throw .remintLimitReached(count) }
    count += 1
    let also: @Sendable (Database) throws -> Void
    switch mode {
    case .keepState: also = { _ in }
    case .rebuild: also = { try SyncAppliedTable.clear($0) }
    }
    do {
      _ = try await lifecycle.remint(reason: reason, mode: mode, also: also)
      return true
    } catch {
      let replica = store.replica
      let phase = try? await read { try ReplicaLifecyclePhase.load($0.database) }
      if phase != .claimed(replica) { readiness = .resumeRequired }
      guard case .markerUnavailable = error else { throw SyncError(converting: error) }
      return false
    }
  }

  /// Re-stamps only a change a rebuild can lower: off against trusted time, and not within tolerance of the public floor a rebuild restarts above.
  private func isClockCorrectionNeeded() async throws(SyncError) -> Bool {
    guard provider.capabilities.reportsServerTime, case .estimate(let trusted) = trustedClock.now() else {
      deviceClock = .unchecked
      return false
    }
    let skew = wallClock().timeIntervalSince(trusted)
    let tolerance = configuration.clockTolerance.timeInterval
    let isWrong = abs(skew) > tolerance
    deviceClock = isWrong ? .wrong(skew: .seconds(skew)) : .correct
    let storeSkew = store.wallClock().timeIntervalSince(trusted)
    guard abs(storeSkew) <= tolerance else { throw .storeClockUntrusted(skew: .seconds(storeSkew)) }
    let floor = try await publicFloor().map { $0.date.timeIntervalSince(trusted) }
    let offsets = try await pendingChanges().map { $0.record.clock.date.timeIntervalSince(trusted) }
    return offsets.contains { offset in
      let isOff = offset > configuration.futureLimit.timeInterval || (isWrong && (skew > 0 ? offset > tolerance : offset < -tolerance))
      return isOff && floor.map { offset > $0 + tolerance } ?? true
    }
  }

  private func sendPending(sealedWith key: VaultKey) async throws(SyncError) -> [StreamPoint] {
    var points: [StreamPoint] = []
    while true {
      let pending = try await nextPass()
      guard !pending.isEmpty else { return points }
      try refuseUnstorable(pending)
      for entry in try await sealPass(pending, with: key) {
        let millis = millis
        try await write { try SyncOutbox.save(entry, at: millis, in: $0.database) }
        try checkpoint(.outboxSaved)
        points.append(try await finish(entry))
      }
    }
  }

  private func refuseUnstorable(_ pending: [SyncPendingChange]) throws(SyncError) {
    let policy = provider.capabilities.classPolicy
    for change in pending {
      let syncClass = store.registry[change.record.entity]?.syncClass
      guard let syncClass, policy.admits(syncClass) else { throw .syncClassRefused(kind: change.record.entity, syncClass: syncClass) }
    }
  }

  /// Seals every segment of the pass before the first put, so a change that cannot fit stops the pass with nothing put.
  private func sealPass(_ pending: [SyncPendingChange], with key: VaultKey) async throws(SyncError) -> [SyncOutboxEntry] {
    let replica = store.replica
    let (head, dependencies) = try await read { transaction in
      (try ReplicaHistory.head(of: replica, in: transaction.database), try SyncAppliedTable.points(excluding: replica, in: transaction.database))
    }
    var previous = head
    let limit = provider.capabilities.maxObjectBytes
    var entries: [SyncOutboxEntry] = []
    var remaining = pending[...]
    while !remaining.isEmpty {
      var count = packedCount(remaining)
      while true {
        let batch = remaining.prefix(count)
        if let sealed = try sealSegment(batch, replica: replica, previous: previous, dependencies: dependencies, key: key), sealed.data.count <= limit {
          let first = batch[batch.startIndex].sequence
          let last = batch[batch.endIndex - 1].sequence
          let entry = SyncOutboxEntry(replica: replica, key: sealed.key, first: first, last: last, tag: sealed.tag, data: sealed.data)
          entries.append(entry)
          previous = entry.point
          remaining = remaining.dropFirst(count)
          break
        }
        guard count > 1 else { throw .changeTooLarge(sequence: batch[batch.startIndex].sequence, limit: limit) }
        count /= 2
      }
    }
    return entries
  }

  private func packedCount(_ pending: ArraySlice<SyncPendingChange>) -> Int {
    let lineLimit = min(max(configuration.maximumSegmentLines, 1), SegmentCodec.maximumLineCount)
    var count = 0
    var bytes = 0
    for change in pending {
      let size = change.line.count + 1
      guard count < lineLimit, count == 0 || bytes + size <= configuration.maximumSegmentBytes else { break }
      count += 1
      bytes += size
    }
    return count
  }

  private func sealSegment(
    _ batch: ArraySlice<SyncPendingChange>, replica: ReplicaID, previous: StreamPoint?, dependencies: [ReplicaID: StreamPoint], key: VaultKey
  ) throws(SyncError) -> SealedFile? {
    guard let first = batch.first?.sequence, let last = batch.last?.sequence, zip(batch, first...).allSatisfy({ $0.sequence == $1 }) else {
      throw .corruptState("the pending changes are not contiguous")
    }
    let schema = batch.map(\.record.schema).max() ?? 0
    guard let header = SegmentHeader(replica: replica, first: first, last: last, previous: previous, dependencies: dependencies, schema: schema) else {
      throw .corruptState("the pending changes do not continue the uploaded stream")
    }
    guard let file = SegmentFile(header: header, lines: batch.map(\.line)) else { throw .corruptState("a pending change is not a segment line") }
    do {
      return try SegmentCodec.seal(file, vault: vault, with: key)
    } catch {
      guard case .payloadTooLarge = error else { throw .codec(error) }
      return nil
    }
  }

  /// The store reads pending changes by count only, so the count grows until the byte budget is reached; a strict byte bound needs a store query by size.
  private func nextPass() async throws(SyncError) -> [SyncPendingChange] {
    let budget = max(configuration.uploadPassBytes, 1)
    var limit = 16
    while true {
      let logged = try await storeCall { () async throws(StoreError) in try await store.pendingChanges(limit: limit) }
      var bytes = 0
      var count = 0
      for change in logged {
        let size = change.line.count + 1
        guard count == 0 || bytes + size <= budget else { break }
        bytes += size
        count += 1
      }
      if count < logged.count || logged.count < limit { return try decode(logged.prefix(count)) }
      limit = count * 2
    }
  }

  private func pendingChanges() async throws(SyncError) -> [SyncPendingChange] {
    try decode(try await storeCall { () async throws(StoreError) in try await store.pendingChanges(limit: Int.max) })
  }

  private func decode(_ logged: some Collection<LoggedChange>) throws(SyncError) -> [SyncPendingChange] {
    var changes: [SyncPendingChange] = []
    changes.reserveCapacity(logged.count)
    for change in logged {
      guard let json = try? CanonicalJSON.decode(change.line), let record = try? ChangeRecord(json: json) else {
        throw .corruptState("pending change \(change.sequence) is not a change record")
      }
      changes.append(SyncPendingChange(sequence: change.sequence, line: change.line, record: record))
    }
    return changes
  }

  private var millis: Int64 {
    max(0, Int64((wallClock().timeIntervalSince1970 * 1_000).rounded(.down)))
  }

  private func acquire() async {
    while isBusy { await withCheckedContinuation { waiters.append($0) } }
    isBusy = true
  }

  private func release() {
    isBusy = false
    guard !waiters.isEmpty else { return }
    waiters.removeFirst().resume()
  }

  private func read<T: Sendable>(_ body: @Sendable (ReadTransaction) throws -> T) async throws(SyncError) -> T {
    do {
      return try await store.read(body)
    } catch {
      throw SyncError(converting: error)
    }
  }

  private func write<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws -> T) async throws(SyncError) -> T {
    do {
      return try await store.write(body)
    } catch {
      throw SyncError(converting: error)
    }
  }

  private func storeCall<T>(_ body: () async throws(StoreError) -> T) async throws(SyncError) -> T {
    do {
      return try await body()
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

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
