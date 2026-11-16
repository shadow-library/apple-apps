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

struct SyncSettledUploads: Sendable {
  let replica: ReplicaID
  let key: VaultKey
  let listing: [StorageObject]
  let uploaded: [StreamPoint]
  let reminted: Bool
}

enum SyncSettleResult: Sendable {
  case settled(SyncSettledUploads)
  case postponed
  case awaitingKey(floor: KeyID?)
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
  private let checkpoint: @Sendable (SyncUploadStep) async throws(SyncError) -> Void
  private let downloadCheckpoint: @Sendable (SyncDownloadStep) throws(SyncError) -> Void
  private let compactionCheckpoint: @Sendable (SyncCompactionStep) async throws(SyncError) -> Void
  private let adoptionCheckpoint: @Sendable (SyncAdoptionStep) async throws(SyncError) -> Void
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
    checkpoint: @escaping @Sendable (SyncUploadStep) async throws(SyncError) -> Void,
    downloadCheckpoint: @escaping @Sendable (SyncDownloadStep) throws(SyncError) -> Void = { _ throws(SyncError) in },
    compactionCheckpoint: @escaping @Sendable (SyncCompactionStep) async throws(SyncError) -> Void = { _ async throws(SyncError) in },
    adoptionCheckpoint: @escaping @Sendable (SyncAdoptionStep) async throws(SyncError) -> Void = { _ async throws(SyncError) in }
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
    self.compactionCheckpoint = compactionCheckpoint
    self.adoptionCheckpoint = adoptionCheckpoint
    self.publicFloor = publicFloor
  }

  public static var migrations: [StoreMigration] {
    ReplicaLifecycle.migrations + [
      SyncEngineSchema.migration, SyncEngineSchema.heldMigration, SyncEngineSchema.compactionMigration, SyncEngineSchema.adoptionMigration, SyncEngineSchema.strayMigration,
    ]
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
    return try await postponing(.postponed) { () async throws(SyncError) in try await performUpload() }
  }

  public func download() async throws(SyncError) -> SyncDownloadOutcome {
    await acquire()
    defer { release() }
    return try await postponing(Self.postponedDownload) { () async throws(SyncError) in try await performDownload() }
  }

  public func sync() async throws(SyncError) -> (download: SyncDownloadOutcome, upload: SyncUploadOutcome) {
    await acquire()
    defer { release() }
    let download = try await postponing(Self.postponedDownload) { () async throws(SyncError) in try await performDownload() }
    return (download, try await postponing(.postponed) { () async throws(SyncError) in try await performUpload() })
  }

  /// Compacts only a replica whose upload side is at rest, after the same self-check, clock check and passes `upload()` runs.
  public func compact(force: Bool = false) async throws(SyncError) -> SyncCompactionOutcome {
    await acquire()
    defer { release() }
    return try await postponing(.postponed) { () async throws(SyncError) in try await performCompaction(force: force) }
  }

  /// Takes over retired replicas' files so their prefixes can be removed, after the same self-check, clock check and passes `upload()` runs.
  public func adopt() async throws(SyncError) -> SyncAdoptionOutcome {
    await acquire()
    defer { release() }
    return try await postponing(.postponed) { () async throws(SyncError) in try await performAdoption() }
  }

  private static let postponedDownload = SyncDownloadOutcome(applied: [], held: [:], missingKeys: [:], reminted: false, postponed: true)

  private func postponing<T>(_ postponed: T, _ body: () async throws(SyncError) -> T) async throws(SyncError) -> T {
    do {
      return try await body()
    } catch {
      guard case .replicaChanged = error else { throw error }
      return postponed
    }
  }

  private func performCompaction(force: Bool) async throws(SyncError) -> SyncCompactionOutcome {
    guard case .settled(let settled) = try await settleUploads(), !settled.reminted else { return .postponed }
    let context = SyncCompactionContext(
      store: store, provider: provider, vault: vault, lifecycle: lifecycle, trustedClock: trustedClock, configuration: configuration, replica: settled.replica,
      key: settled.key, now: preferredNow, checkpoint: compactionCheckpoint
    ) { key, replica async throws(SyncError) in try await self.putManifest(sealedWith: key, as: replica) }
    return try await SyncCompactor(context: context).run(force: force, listing: settled.listing)
  }

  private func performAdoption() async throws(SyncError) -> SyncAdoptionOutcome {
    guard case .settled(let settled) = try await settleUploads(), !settled.reminted else { return .postponed }
    let replica = settled.replica
    let directory = try await lifecycleCall { () async throws(ReplicaLifecycleError) in try await lifecycle.directory() }
    let context = SyncAdoptionContext(
      store: store, provider: provider, vault: vault, ring: ring, lifecycle: lifecycle, configuration: configuration, replica: replica, directory: directory,
      limit: try readerLimit(), now: preferredNow, checkpoint: adoptionCheckpoint,
      upload: { () async throws(SyncError) -> Bool in
        guard case .settled(let again) = try await self.settleUploads(), !again.reminted, again.replica == replica else { return false }
        return true
      },
      compact: { () async throws(SyncError) -> SyncCompactionOutcome in
        guard self.store.replica == replica else { throw .replicaChanged }
        return try await self.performCompaction(force: true)
      },
      remint: { found async throws(SyncError) in try await self.remintOnCollision(replica, found: found) })
    return try await SyncAdopter(context: context).run()
  }

  private func remintOnCollision(_ replica: ReplicaID, found: ReplicaID) async throws(SyncError) {
    var remints = 0
    _ = try await remint(replica, reason: .replicaCollision(found: found), mode: .keepState, count: &remints)
  }

  private func performUpload() async throws(SyncError) -> SyncUploadOutcome {
    switch try await settleUploads() {
    case .postponed: return .postponed
    case .awaitingKey(let floor): return .awaitingKey(floor: floor)
    case .settled(let settled): return settled.uploaded.isEmpty ? .nothingToUpload : .uploaded(settled.uploaded)
    }
  }

  /// The replica is read once and passed to every step; only this call's own re-mints move it.
  private func settleUploads() async throws(SyncError) -> SyncSettleResult {
    guard try await resume() else { return .postponed }
    var replica = store.replica
    try await requireClaimed(replica)
    try await refuseNewerSchema(as: replica)
    try await repairDroppedChanges(of: replica)
    var uploaded = try await finishInFlight(as: replica).map { [$0] } ?? []
    var remints = 0
    var corrected = false
    while true {
      let floor = try await raisedFloors(as: replica).key
      guard let key = try await writingKey(floor: floor) else { return .awaitingKey(floor: floor) }
      let (verdict, listing) = try await selfCheck(of: replica)
      switch verdict {
      case .postpone:
        return .postponed
      case .remint(let reason):
        guard let next = try await remint(replica, reason: reason, mode: .keepState, count: &remints) else { return .postponed }
        replica = next
        continue
      case .pass:
        break
      }
      if provider.capabilities.reportsServerTime { try await putManifest(sealedWith: key, as: replica) }
      if try await isClockCorrectionNeeded(), !corrected {
        corrected = true
        guard let next = try await remint(replica, reason: .clockCorrected, mode: .rebuild, count: &remints) else { return .postponed }
        replica = next
        continue
      }
      uploaded += try await sendPending(sealedWith: key, as: replica)
      return .settled(SyncSettledUploads(replica: replica, key: key, listing: listing, uploaded: uploaded, reminted: remints > 0))
    }
  }

  /// Saves the floors it reads only while the database is claimed; before that it only reads them.
  public func minimumSchema() async throws(SyncError) -> Int? {
    do {
      return try await raisedFloors(as: store.replica).schema
    } catch {
      guard case .replicaChanged = error else { throw error }
      let directory = try await lifecycleCall { () async throws(ReplicaLifecycleError) in try await lifecycle.directory() }
      let saved = try await read { try SyncFloorTable.load($0.database) }
      return [saved.schema, directory.minimumSchema].compactMap(\.self).max()
    }
  }

  public func appliedPoints() async throws(SyncError) -> [ReplicaID: StreamPoint] {
    let replica = store.replica
    return try await read { try SyncAppliedTable.points(excluding: replica, in: $0.database) }
  }

  private func performDownload() async throws(SyncError) -> SyncDownloadOutcome {
    guard try await resume() else { return Self.postponedDownload }
    var replica = store.replica
    try await requireClaimed(replica)
    try await refuseNewerSchema(as: replica)
    do {
      try ring.refresh()
    } catch {
      throw .keyRing(error)
    }
    let previous = try await read { try SyncHeldTable.load($0.database) }
    let context = SyncDownloadContext(
      store: store, provider: provider, vault: vault, ring: ring, configuration: configuration, limit: try readerLimit(), wallClock: preferredNow,
      checkpoint: downloadCheckpoint)
    var session = SyncDownloadSession(context: context, previous: previous, unsupported: unsupportedFiles)
    defer { unsupportedFiles = session.unsupported }
    var remints = 0
    var postponed = false
    var listing = try await listForeignFiles(excluding: replica)
    while case .collision(let found) = try await session.run(listing, as: replica) {
      guard let next = try await remint(replica, reason: .replicaCollision(found: found), mode: .keepState, count: &remints) else {
        postponed = true
        break
      }
      replica = next
      session.noteRemint()
      listing = try await listForeignFiles(excluding: replica)
    }
    let rows = session.retainedRows
    let listed = postponed ? nil : SyncListing.ids(listing)
    let own = replica
    try await write(as: own) { transaction in
      try SyncHeldTable.replace(with: rows, in: transaction.database)
      if let listed { try SyncAppliedTable.prune(keeping: listed, excluding: own, in: transaction.database) }
    }
    if !postponed { _ = try await raisedFloors(as: replica) }
    return session.outcome(postponed: postponed)
  }

  private func requireClaimed(_ replica: ReplicaID) async throws(SyncError) {
    try await read { try SyncReplicaGuard.require(replica, in: $0.database) }
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

  private func refuseNewerSchema(as replica: ReplicaID) async throws(SyncError) {
    guard let minimum = try await raisedFloors(as: replica).schema, minimum > store.registry.version else { return }
    throw .appUpdateRequired(minimumSchema: minimum, current: store.registry.version)
  }

  private func listForeignFiles(excluding replica: ReplicaID) async throws(SyncError) -> [ReplicaID: SyncListedReplica] {
    do {
      return SyncListing.group(try await provider.listAll(prefix: VaultPath.replicasPrefix), excluding: replica)
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

  private func repairDroppedChanges(of replica: ReplicaID) async throws(SyncError) {
    guard let head = try await read({ try ReplicaHistory.head(of: replica, in: $0.database) }) else { return }
    guard let first = try await storeCall({ () async throws(StoreError) in try await store.pendingChanges(limit: 1).first }), first.sequence <= head.last else { return }
    try await dropChanges(through: head.last, of: replica)
  }

  private func dropChanges(through sequence: Int64, of replica: ReplicaID) async throws(SyncError) {
    try await storeCall { () async throws(StoreError) in try await store.dropChanges(through: sequence) { try SyncReplicaGuard.require(replica, in: $0) } }
  }

  /// A saved upload of an earlier id was re-logged by the re-mint that retired that id, so it is dropped rather than put under a prefix this database left.
  private func finishInFlight(as replica: ReplicaID) async throws(SyncError) -> StreamPoint? {
    guard let entry = try await read({ try SyncOutbox.load($0.database) }) else { return nil }
    guard entry.replica == replica else {
      try await write(as: replica) { try SyncOutbox.clear($0.database) }
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
    try await checkpoint(.putDone)
    let millis = millis
    try await write(as: entry.replica) { transaction in
      try ReplicaHistory.recordSegment(entry.point, first: entry.first, replica: entry.replica, at: millis, in: transaction.database)
      try SyncOutbox.clear(transaction.database)
    }
    try await checkpoint(.recorded)
    try await dropChanges(through: entry.last, of: entry.replica)
    try await checkpoint(.dropped)
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
  private func raisedFloors(as replica: ReplicaID) async throws(SyncError) -> SyncFloors {
    let directory = try await lifecycleCall { () async throws(ReplicaLifecycleError) in try await lifecycle.directory() }
    let read = SyncFloors(key: directory.keyFloor, schema: directory.minimumSchema)
    return try await write(as: replica) { try SyncFloorTable.raise(to: read, in: $0.database) }
  }

  private func putManifest(sealedWith key: VaultKey, as replica: ReplicaID) async throws(SyncError) {
    let applied = try await read { try SyncAppliedTable.points(excluding: replica, in: $0.database) }
    let manifest = try await lifecycleCall { () async throws(ReplicaLifecycleError) in try await lifecycle.manifest(applied: applied) }
    guard manifest.replica == replica else { throw .replicaChanged }
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

  private func selfCheck(of replica: ReplicaID) async throws(SyncError) -> (ReplicaSelfCheckVerdict, [StorageObject]) {
    let listing: [StorageObject]
    do {
      listing = try await provider.listAll(prefix: VaultPath.replicaPrefix(replica))
    } catch {
      throw .storage(error)
    }
    let verdict = try await lifecycleCall { () async throws(ReplicaLifecycleError) in try await lifecycle.selfCheck(listing: listing.map(\.key)) }
    guard store.replica == replica else { throw .replicaChanged }
    return (verdict, listing)
  }

  /// Returns nil when the device marker cannot be read; the lifecycle checks it before changing anything.
  private func remint(_ replica: ReplicaID, reason: RemintReason, mode: RemintMode, count: inout Int) async throws(SyncError) -> ReplicaID? {
    guard count < Self.maximumRemintsPerUpload else { throw .remintLimitReached(count) }
    count += 1
    try await requireClaimed(replica)
    let also: @Sendable (Database) throws -> Void = { db in
      guard case .moving(_, let retiring, _, _) = try ReplicaLifecyclePhase.load(db), retiring == replica else { throw SyncError.replicaChanged }
      try SyncCompactionTable.clear(db)
      try SyncAdoptionTable.clear(db)
      if mode == .rebuild { try SyncAppliedTable.clear(db) }
    }
    do {
      return try await lifecycle.remint(reason: reason, mode: mode, also: also)
    } catch {
      let current = store.replica
      let phase = try? await read { try ReplicaLifecyclePhase.load($0.database) }
      if phase != .claimed(current) { readiness = .resumeRequired }
      guard case .markerUnavailable = error else { throw SyncError(converting: error) }
      return nil
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
    let offsets = try await storeCall { () async throws(StoreError) in try await store.pendingClocks() }.map { $0.date.timeIntervalSince(trusted) }
    return offsets.contains { offset in
      let isOff = offset > configuration.futureLimit.timeInterval || (isWrong && (skew > 0 ? offset > tolerance : offset < -tolerance))
      return isOff && floor.map { offset > $0 + tolerance } ?? true
    }
  }

  private func sendPending(sealedWith key: VaultKey, as replica: ReplicaID) async throws(SyncError) -> [StreamPoint] {
    var points: [StreamPoint] = []
    while true {
      let pending = try await nextPass()
      guard !pending.isEmpty else { return points }
      try refuseUnstorable(pending)
      for entry in try await sealPass(pending, as: replica, with: key) {
        let millis = millis
        try await write(as: replica) { try SyncOutbox.save(entry, at: millis, in: $0.database) }
        try await checkpoint(.outboxSaved)
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
  private func sealPass(_ pending: [SyncPendingChange], as replica: ReplicaID, with key: VaultKey) async throws(SyncError) -> [SyncOutboxEntry] {
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

  private func nextPass() async throws(SyncError) -> [SyncPendingChange] {
    let budget = max(configuration.uploadPassBytes, 1)
    return try decode(try await storeCall { () async throws(StoreError) in try await store.pendingChanges(limit: Int.max, maximumBytes: budget) })
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
    max(0, Int64((preferredNow().timeIntervalSince1970 * 1_000).rounded(.down)))
  }

  /// Upload and compaction times: trusted time when the engine has a sample, the device clock otherwise.
  private var preferredNow: @Sendable () -> Date {
    Self.wallClock(preferring: trustedClock, device: wallClock)
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

  private func write<T: Sendable>(as replica: ReplicaID, _ body: @Sendable (inout WriteTransaction) throws -> T) async throws(SyncError) -> T {
    do {
      return try await store.write { transaction in
        try SyncReplicaGuard.require(replica, in: transaction.database)
        return try body(&transaction)
      }
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
