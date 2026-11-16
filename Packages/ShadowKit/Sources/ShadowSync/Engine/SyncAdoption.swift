import Foundation
import GRDB
import ShadowCore
import ShadowStore

public enum SyncAdoptionOutcome: Sendable, Equatable {
  case nothingToAdopt
  /// `adopted`: nothing of these replicas is left to do; `waiting`: folded, published or holding files back until a later call.
  case progressed(adopted: [ReplicaID], waiting: [ReplicaID])
  case postponed
}

enum SyncAdoptionStep: Sendable, Equatable, CaseIterable {
  case folded
  case published
  case uploaded
  case deleted
  case foldsRemoved
  case manifestDeleted
}

struct SyncAdoptionContext: Sendable {
  let store: VaultStore
  let provider: any StorageProvider
  let vault: VaultID
  let ring: KeyRing
  let lifecycle: ReplicaLifecycle
  let configuration: SyncConfiguration
  let replica: ReplicaID
  let directory: ReplicaDirectory
  let limit: HLCTimestamp
  let now: @Sendable () -> Date
  let checkpoint: @Sendable (SyncAdoptionStep) async throws(SyncError) -> Void
  /// Brings the upload side to rest under `replica`; false when that cannot happen in this call.
  let upload: @Sendable () async throws(SyncError) -> Bool
  let compact: @Sendable () async throws(SyncError) -> SyncCompactionOutcome
  let remint: @Sendable (_ found: ReplicaID) async throws(SyncError) -> Void

  var millis: Int64 {
    max(0, Int64((now().timeIntervalSince1970 * 1_000).rounded(.down)))
  }
}

private enum SyncFoldResult {
  case complete
  case stopped
  case collision
  case raced
}

/// A rebuild clears the vault's copy of the directory until it is downloaded again, so a replica read as retired can read as not retired in a later transaction.
private struct SyncNotRetired: Error {}

/// Another engine on this database published the replica's fact since this call read its rows.
private struct SyncAlreadyPublished: Error {}

private struct SyncOpenedFile {
  enum Kind {
    case segment(StreamPoint, first: Int64)
    case basePart(SyncBaseName)
  }

  let lines: [Data]
  let kind: Kind
}

/// Deletes under another replica's prefix only names it folded, and only once a base of its own that holds them is listed: a listing never shows every file.
struct SyncAdopter {
  let context: SyncAdoptionContext

  func run() async throws(SyncError) -> SyncAdoptionOutcome {
    let replica = context.replica
    if try await read({ try SyncAdoptionTable.hasRows(otherThan: replica, in: $0) }) {
      try await write { try SyncAdoptionTable.clear(otherThan: replica, in: $0.database) }
    }
    let (rows, folds) = try await read { db in (try SyncAdoptionTable.rows(of: replica, in: db), try SyncAdoptionTable.folds(of: replica, in: db)) }
    let listing = try await listReplicas()
    try await forgetStraysListingFiles(listing)
    let leftManifests = rows.keys.filter { Self.showsOnlyManifest(listing[$0] ?? [], of: $0) }
    let targets = Set(volunteers(listing)).union(rows.values.filter { $0.phase == .published }.map(\.adopted)).union(folds.filter { !$0.value.isEmpty }.map(\.key))
      .union(leftManifests).subtracting([replica]).sorted()
    guard !targets.isEmpty else { return .nothingToAdopt }
    var adopted: [ReplicaID] = []
    var waiting: Set<ReplicaID> = []
    var finishing: [ReplicaID] = []
    for target in targets {
      if rows[target]?.phase == .published {
        finishing.append(target)
        continue
      }
      switch try await fold(target, listed: listing[target] ?? [], folded: folds[target] ?? [:]) {
      case .collision:
        try await context.remint(target)
        return .postponed
      case .raced:
        return .postponed
      case .stopped:
        waiting.insert(target)
      case .complete:
        let (current, rows) = try await read { db in (try SyncAdoptionTable.folds(of: replica, in: db)[target] ?? [:], try SyncAdoptionTable.rows(of: replica, in: db)) }
        let start = heldHead(of: target, rows: rows)
        if current.values.contains(where: { !$0.published }) || (!current.isEmpty && start > (rows[target]?.through ?? 0)) {
          if try await publish(target, from: start) { finishing.append(target) } else { waiting.insert(target) }
        } else if !current.isEmpty {
          finishing.append(target)
        } else if rows[target] == nil, try await !hasStayedStray(target) {
          waiting.insert(target)
        } else {
          try await finish(target, manifestListed: !(listing[target] ?? []).isEmpty)
          adopted.append(target)
        }
      }
    }
    guard !finishing.isEmpty else { return Self.outcome(adopted: adopted, waiting: waiting) }
    guard try await context.upload() else { return .postponed }
    try await context.checkpoint(.uploaded)
    if try await !isCarried(finishing) {
      guard try await context.compact() != .postponed else { return Self.outcome(adopted: adopted, waiting: waiting.union(finishing)) }
    }
    let ownListing = try await list(VaultPath.replicaPrefix(replica))
    for target in finishing {
      if try await mayDelete(target, ownListing: ownListing), try await deleteFolded(target, listed: Set((listing[target] ?? []).map(\.key))) {
        adopted.append(target)
      } else {
        waiting.insert(target)
      }
    }
    return Self.outcome(adopted: adopted, waiting: waiting)
  }

  private static func outcome(adopted: [ReplicaID], waiting: Set<ReplicaID>) -> SyncAdoptionOutcome {
    .progressed(adopted: adopted.sorted(), waiting: waiting.sorted())
  }

  private static func showsOnlyManifest(_ objects: [StorageObject], of replica: ReplicaID) -> Bool {
    objects.contains { $0.key == VaultPath.manifest(replica) } && !objects.contains { isFoldable($0.key, of: replica) }
  }

  /// A prefix a stale listing shows as its manifest alone may still hold files, so it is finished only once it has listed so for the abandon delay.
  private func hasStayedStray(_ adopted: ReplicaID) async throws(SyncError) -> Bool {
    let replica = context.replica
    let now = context.millis
    let seen = try await write { try SyncAdoptionTable.straySeen(of: adopted, by: replica, now: now, in: $0.database) }
    return now - min(seen, now) >= context.configuration.adoptionAbandonDelay.milliseconds
  }

  private func forgetStraysListingFiles(_ listing: [ReplicaID: [StorageObject]]) async throws(SyncError) {
    let replica = context.replica
    let strays = try await read { try SyncAdoptionTable.strays(of: replica, in: $0) }
    let listingFiles = strays.filter { stray in (listing[stray] ?? []).contains { Self.isFoldable($0.key, of: stray) } }
    guard !listingFiles.isEmpty else { return }
    try await write { transaction in
      for stray in listingFiles { try SyncAdoptionTable.forgetStray(stray, by: replica, in: transaction.database) }
    }
  }

  /// A retired replica this one should adopt: it already published a fact about it, whose head covers its later files wherever an earlier-stamped successor
  /// moved the chain; or its chain of successors ends here, or nowhere active and this is the lowest active id.
  private func volunteers(_ listing: [ReplicaID: [StorageObject]]) -> [ReplicaID] {
    let directory = context.directory
    let now = context.millis
    let delay = context.configuration.adoptionDelay.milliseconds
    let lowestActive = directory.replicas.filter { $0.state == .active }.map(\.replica).min()
    return directory.replicas.compactMap { entry in
      guard entry.state == .retired, entry.replica != context.replica, let retired = entry.retired else { return nil }
      guard retired <= now, now - retired >= delay else { return nil }
      let listed = listing[entry.replica] ?? []
      let isStray = Self.showsOnlyManifest(listed, of: entry.replica)
      guard listed.contains(where: { Self.isFoldable($0.key, of: entry.replica) }) || isStray else { return nil }
      if directory.adoptions.contains(where: { $0.adopted == entry.replica && $0.adopter == context.replica }) { return entry.replica }
      switch chainEnd(from: entry.replica) {
      case .some(let end): return end == context.replica ? entry.replica : nil
      case .none: return lowestActive == context.replica ? entry.replica : nil
      }
    }
  }

  private func chainEnd(from start: ReplicaID) -> ReplicaID? {
    var visited: Set<ReplicaID> = []
    var current = start
    while visited.insert(current).inserted {
      guard let entry = context.directory.entry(for: current) else { return nil }
      if entry.state == .active { return current }
      guard let successor = entry.successor else { return nil }
      current = successor
    }
    return nil
  }

  private static func isFoldable(_ key: ObjectKey, of replica: ReplicaID) -> Bool {
    switch VaultPath.classify(key) {
    case .segment(let owner, _, _, _), .basePart(let owner, _, _, _, _): owner == replica
    default: false
    }
  }

  /// Folds every listed segment and base part not folded yet, each in one transaction with its fold row; the first that cannot be folded stops this replica for the call.
  private func fold(_ adopted: ReplicaID, listed: [StorageObject], folded: [ObjectKey: SyncFoldRow]) async throws(SyncError) -> SyncFoldResult {
    for object in listed.sorted(by: { $0.key < $1.key }) where Self.isFoldable(object.key, of: adopted) && folded[object.key] == nil {
      guard context.directory.isRetired(adopted) else { return .stopped }
      guard let data = try await fetch(object.key), let file = open(data, at: object.key) else { return .stopped }
      switch try await merge(file, at: object.key, of: adopted) {
      case .complete: try await context.checkpoint(.folded)
      case .stopped: return .stopped
      case .collision: return .collision
      case .raced: return .raced
      }
    }
    return .complete
  }

  private func fetch(_ key: ObjectKey) async throws(SyncError) -> Data? {
    do {
      return try await context.provider.get(key)
    } catch {
      switch error {
      case .notFound, .tooLarge, .keyConflict, .underlying, .alreadyExists: return nil
      case .unavailable, .rateLimited, .quotaExceeded, .unauthenticated: throw .storage(error)
      }
    }
  }

  /// Parts are self-contained, so a part of a base whose other parts are missing is folded on its own.
  private func open(_ data: Data, at key: ObjectKey) -> SyncOpenedFile? {
    let ring = context.ring
    switch VaultPath.classify(key) {
    case .segment(_, let first, let last, let tag):
      guard let file = try? SegmentCodec.open(data, at: key, vault: context.vault, keys: { ring.key($0) }) else { return nil }
      return SyncOpenedFile(lines: file.lines, kind: .segment(StreamPoint(last: last, tag: tag), first: first))
    case .basePart(_, let upTo, let tag, _, let parts):
      guard let part = try? BaseCodec.openPart(data, at: key, vault: context.vault, keys: { ring.key($0) }) else { return nil }
      return SyncOpenedFile(lines: part.lines, kind: .basePart(SyncBaseName(upTo: upTo, tag: tag, parts: parts)))
    default:
      return nil
    }
  }

  private func merge(_ file: SyncOpenedFile, at key: ObjectKey, of adopted: ReplicaID) async throws(SyncError) -> SyncFoldResult {
    let replica = context.replica
    let registry = context.store.registry
    let millis = context.millis
    do {
      _ = try await context.store.adoptRemote(file.lines, notAfter: context.limit) { db in
        try SyncReplicaGuard.require(replica, in: db)
        guard ReplicaDirectory.isRetired(try ReadTransaction(database: db, registry: registry).state(of: SyncKernelSchema.replicaRef(adopted))) else { throw SyncNotRetired() }
        var row = try SyncAdoptionTable.rows(of: replica, in: db)[adopted] ?? SyncAdoptionRow(adopted: adopted, phase: .folding)
        guard row.phase != .published else { throw SyncAlreadyPublished() }
        row.phase = .folding
        try SyncAdoptionTable.save(row, of: replica, in: db)
        switch file.kind {
        case .segment(let point, let first):
          try SyncAdoptionTable.recordFold(SyncFoldRow(adopted: adopted, key: key, first: first, last: point.last), of: replica, in: db)
          try SyncAppliedTable.record(point, first: first, isBase: false, replica: adopted, at: millis, in: db)
          try SyncHeldTable.remove(SyncFileID(replica: adopted, kind: .segment, point: point), in: db)
        case .basePart(let base):
          try SyncAdoptionTable.recordFold(SyncFoldRow(adopted: adopted, key: key, first: nil, last: base.upTo), of: replica, in: db)
          guard try SyncAdoptionTable.foldedKeys(of: adopted, by: replica, in: db).isSuperset(of: base.keys(of: adopted)) else { return }
          let point = StreamPoint(last: base.upTo, tag: base.tag)
          try SyncAppliedTable.record(point, first: nil, isBase: true, replica: adopted, at: millis, in: db)
          try SyncHeldTable.remove(SyncFileID(replica: adopted, kind: .base, point: point), in: db)
        }
      }
    } catch {
      switch error {
      case .replicaCollision: return .collision
      case .clockAhead: return .stopped
      case .aborted(let underlying) where underlying is SyncNotRetired: return .stopped
      case .aborted(let underlying) where underlying is SyncAlreadyPublished: return .raced
      default: throw SyncError(converting: error)
      }
    }
    return .complete
  }

  /// The highest `through` of a fact about `adopted` whose content this replica's own writes hold: it published the fact, or it folded the fact adopter's complete base
  /// reaching `at`, or an adopter of that adopter whose content it holds folded such a base.
  private func heldHead(of adopted: ReplicaID, rows: [ReplicaID: SyncAdoptionRow]) -> Int64 {
    let facts = Dictionary(grouping: context.directory.adoptions, by: \.adopted)
    func isHeld(_ fact: SyncAdoptionFact, visited: Set<ReplicaID>) -> Bool {
      if fact.adopter == context.replica || (rows[fact.adopter]?.baseUpTo ?? 0) >= fact.at { return true }
      guard !visited.contains(fact.adopter) else { return false }
      return (facts[fact.adopter] ?? []).contains { $0.baseUpTo >= fact.at && isHeld($0, visited: visited.union([fact.adopter])) }
    }
    return (facts[adopted] ?? []).filter { isHeld($0, visited: [adopted]) }.map(\.through).max() ?? 0
  }

  /// Writes the fact at the sequence number its own change record takes, so a base that reaches `at` was sealed after every fold it covers.
  private func publish(_ adopted: ReplicaID, from start: Int64) async throws(SyncError) -> Bool {
    let replica = context.replica
    let done = try await write { transaction in
      let db = transaction.database
      guard var row = try SyncAdoptionTable.rows(of: replica, in: db)[adopted], row.phase == .folding else { return false }
      let folds = Array((try SyncAdoptionTable.folds(of: replica, in: db)[adopted] ?? [:]).values)
      guard !folds.isEmpty else { return false }
      let (through, baseUpTo) = Self.coverage(of: folds, adopted: adopted, after: row, from: start)
      let at = try transaction.nextSequence
      let fact = SyncAdoptionFact(adopted: adopted, adopter: replica, through: through, at: at, baseUpTo: baseUpTo)
      try ReplicaDirectory.recordAdoption(fact, in: &transaction)
      guard try transaction.nextSequence == at + 1 else { throw SyncError.corruptState("the adoption fact did not take its sequence number") }
      try SyncAdoptionTable.publishFolds(of: adopted, by: replica, in: db)
      row.phase = .published
      row.through = through
      row.baseUpTo = baseUpTo
      row.at = at
      row.completedBefore = try ReplicaHistory.lastCompletion(in: db)
      try SyncAdoptionTable.save(row, of: replica, in: db)
      return true
    }
    if done { try await context.checkpoint(.published) }
    return done
  }

  /// `through` is the contiguous head of what was folded: a complete base covers 1...upTo, a segment first...last, and a lone part nothing.
  private static func coverage(of folds: [SyncFoldRow], adopted: ReplicaID, after row: SyncAdoptionRow, from start: Int64) -> (through: Int64, baseUpTo: Int64) {
    let folded = Set(folds.map(\.key))
    var spans: [(first: Int64, last: Int64)] = []
    var baseUpTo = row.baseUpTo ?? 0
    for fold in folds {
      if let first = fold.first {
        spans.append((first, fold.last))
      } else if case .basePart(_, let upTo, let tag, _, let parts) = VaultPath.classify(fold.key),
        folded.isSuperset(of: SyncBaseName(upTo: upTo, tag: tag, parts: parts).keys(of: adopted))
      {
        spans.append((1, upTo))
        baseUpTo = max(baseUpTo, upTo)
      }
    }
    var through = max(row.through ?? 0, start)
    for span in spans.sorted(by: { $0.first < $1.first }) where span.first <= through + 1 { through = max(through, span.last) }
    return (through, baseUpTo)
  }

  private func currentBase() async throws(SyncError) -> (entry: SyncUploadEntry?, rows: [ReplicaID: SyncAdoptionRow]) {
    let replica = context.replica
    return try await read { db in
      let entries = try ReplicaHistory.entries(of: replica, in: db)
      return (entries.filter { $0.isCompleteBase && $0.isLive }.max { ($0.completed ?? 0) < ($1.completed ?? 0) }, try SyncAdoptionTable.rows(of: replica, in: db))
    }
  }

  private func isCarried(_ adopted: [ReplicaID]) async throws(SyncError) -> Bool {
    let (base, rows) = try await currentBase()
    guard let base else { return false }
    return adopted.allSatisfy { rows[$0].map { Self.carries(base, $0) } ?? false }
  }

  /// The base completed last reaches the fact and was completed after it: only then does it hold every file the fact covers.
  private static func carries(_ base: SyncUploadEntry, _ row: SyncAdoptionRow) -> Bool {
    guard let at = row.at, let completedBefore = row.completedBefore, let completed = base.completed else { return false }
    return base.point.last >= at && completed > completedBefore
  }

  private func mayDelete(_ adopted: ReplicaID, ownListing: [StorageObject]) async throws(SyncError) -> Bool {
    let (base, rows) = try await currentBase()
    guard let base, let row = rows[adopted], Self.carries(base, row), let parts = base.parts, VaultPath.isPart(1, of: parts) else { return false }
    let listed = Set(ownListing.map(\.key))
    let keys = (1...parts).map { VaultPath.basePart(context.replica, upTo: base.point.last, tag: base.point.tag, part: $0, parts: parts) }
    guard keys.allSatisfy(listed.contains) else { return false }
    let verdict: ReplicaSelfCheckVerdict
    do {
      verdict = try await context.lifecycle.selfCheck(listing: ownListing.map(\.key))
    } catch {
      throw SyncError(converting: error)
    }
    guard context.store.replica == context.replica else { throw .replicaChanged }
    return verdict == .pass
  }

  /// Deletes a segment only within the published head and a base's parts only once all are folded: a file not listed may only be late, and readers trust only the head.
  /// What stays unlisted for the abandon delay is given up: a held row is forgotten, never its file. Returns true when nothing is left to do.
  private func deleteFolded(_ adopted: ReplicaID, listed: Set<ObjectKey>) async throws(SyncError) -> Bool {
    let replica = context.replica
    let now = context.millis
    let abandon = context.configuration.adoptionAbandonDelay.milliseconds
    let (keys, forgotten, settledBases, holding) = try await write { transaction in
      let folds = (try SyncAdoptionTable.folds(of: replica, in: transaction.database)[adopted] ?? [:]).values.filter(\.published)
      let through = try SyncAdoptionTable.rows(of: replica, in: transaction.database)[adopted]?.through ?? 0
      var keys: [ObjectKey] = []
      var forgotten: [ObjectKey] = []
      var bases: [SyncBaseName: [ObjectKey]] = [:]
      var holding = false
      for fold in folds {
        guard case .basePart(_, let upTo, let tag, _, let parts) = VaultPath.classify(fold.key) else {
          guard fold.last > through else {
            keys.append(fold.key)
            continue
          }
          let since = try SyncAdoptionTable.noteListing(fold.key, listed: listed.contains(fold.key), of: adopted, by: replica, now: now, in: transaction.database)
          if let since, now - min(since, now) >= abandon { forgotten.append(fold.key) } else { holding = true }
          continue
        }
        bases[SyncBaseName(upTo: upTo, tag: tag, parts: parts), default: []].append(fold.key)
      }
      var settled: [SyncBaseName] = []
      for (base, parts) in bases {
        let isComplete = Set(parts).isSuperset(of: base.keys(of: adopted))
        let seen = isComplete ? now : try SyncAdoptionTable.gapSeen(base, of: adopted, by: replica, now: now, in: transaction.database)
        guard isComplete || now - min(seen, now) >= abandon else {
          holding = true
          continue
        }
        keys += parts
        settled.append(base)
      }
      return (keys.sorted(), forgotten, settled, holding)
    }
    if !forgotten.isEmpty { try await write { try SyncAdoptionTable.removeFolds(forgotten, of: adopted, by: replica, in: $0.database) } }
    for start in stride(from: 0, to: keys.count, by: SyncCompactor.deleteBatch) {
      let batch = Array(keys[start..<min(start + SyncCompactor.deleteBatch, keys.count)])
      try await delete(batch)
      try await context.checkpoint(.deleted)
      try await write { try SyncAdoptionTable.removeFolds(batch, of: adopted, by: replica, in: $0.database) }
      try await context.checkpoint(.foldsRemoved)
    }
    let remaining = try await holding ? true : list(VaultPath.replicaPrefix(adopted)).contains { Self.isFoldable($0.key, of: adopted) }
    if !remaining {
      try await delete([VaultPath.manifest(adopted)])
      try await context.checkpoint(.manifestDeleted)
    }
    try await write { transaction in
      for base in settledBases { try SyncAdoptionTable.removeGap(base, of: adopted, by: replica, in: transaction.database) }
      guard var row = try SyncAdoptionTable.rows(of: replica, in: transaction.database)[adopted] else { return }
      row.phase = remaining ? .folding : .finished
      try SyncAdoptionTable.save(row, of: replica, in: transaction.database)
    }
    return !remaining
  }

  /// A replica whose files are all gone may still list its manifest, which a delete that took effect late or an earlier crash left behind.
  private func finish(_ adopted: ReplicaID, manifestListed: Bool) async throws(SyncError) {
    let replica = context.replica
    if manifestListed {
      try await delete([VaultPath.manifest(adopted)])
      try await context.checkpoint(.manifestDeleted)
    }
    try await write { transaction in
      try SyncAdoptionTable.forgetStray(adopted, by: replica, in: transaction.database)
      guard var row = try SyncAdoptionTable.rows(of: replica, in: transaction.database)[adopted] else { return }
      row.phase = .finished
      try SyncAdoptionTable.save(row, of: replica, in: transaction.database)
    }
  }

  private func listReplicas() async throws(SyncError) -> [ReplicaID: [StorageObject]] {
    var grouped: [ReplicaID: [StorageObject]] = [:]
    for object in try await list(VaultPath.replicasPrefix) {
      switch VaultPath.classify(object.key) {
      case .segment(let replica, _, _, _), .basePart(let replica, _, _, _, _), .manifest(let replica): grouped[replica, default: []].append(object)
      default: continue
      }
    }
    return grouped
  }

  private func list(_ prefix: String) async throws(SyncError) -> [StorageObject] {
    do {
      return try await context.provider.listAll(prefix: prefix)
    } catch {
      throw .storage(error)
    }
  }

  private func delete(_ keys: [ObjectKey]) async throws(SyncError) {
    guard !keys.isEmpty else { return }
    do {
      try await context.provider.delete(keys)
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

  private func write<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws -> T) async throws(SyncError) -> T {
    let replica = context.replica
    do {
      return try await context.store.write { transaction in
        try SyncReplicaGuard.require(replica, in: transaction.database)
        return try body(&transaction)
      }
    } catch {
      throw SyncError(converting: error)
    }
  }
}
