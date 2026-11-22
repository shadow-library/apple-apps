import Foundation
import GRDB
import OSLog
import ShadowCore
import ShadowStore

private struct SyncBlobCollection {
  var deleted: [BlobID] = []
  var restored: [BlobID] = []
  var evicted: [BlobID] = []
}

/// Removes from storage only blobs this database put, by the part names it recorded, never by prefix. A blob is removed once nothing in the merged vault
/// state or the unsent changes has named it for `blobRetention`, and every active replica has published a manifest showing that it applied every
/// stream as far as this database had when it first found the blob unnamed (its own stream up to the last change it logged, sent or not), while this
/// database has applied each of those replicas' streams as far as its manifest's head. Manifests state applied points only from moments with no unsent change, so every change written before the blob was dropped is then here.
/// A removed blob's local file outlives it by another `blobRetention`, and a held blob that is named but missing from storage is put again, so a reference
/// that arrives late, through a race this rule cannot see, finds its blob restored.
struct SyncBlobCollector {
  let context: SyncBlobContext
  let replica: ReplicaID
  let lifecycle: ReplicaLifecycle

  func run() async throws(SyncError) {
    var rows = try await context.rows([.uploaded, .cached, .deleting, .deleted])
    guard !rows.isEmpty else { return }
    guard try await context.read({ try SyncHeldTable.load($0).isEmpty }) else { return }
    let directory = try await replicaDirectory()
    let retired = Set(directory.replicas.filter { $0.state == .retired }.map(\.replica))
    let replica = replica
    let matcher = BlobIDMatcher(rows.map(\.id))
    let (named, snapshot) = try await context.read { db in
      var named = Set<BlobID>()
      try ReadTransaction(database: db, registry: context.store.registry).forEachStoredBytes { matcher.scan($0, into: &named) }
      var snapshot = try SyncAppliedTable.points(excluding: replica, in: db).mapValues(\.last)
      snapshot[replica] = max(try ReplicaHistory.head(of: replica, in: db)?.last ?? 0, try ReadTransaction(database: db, registry: context.store.registry).lastSequence())
      return (named, snapshot)
    }
    let now = context.millis
    var outcome = SyncBlobCollection()
    for index in rows.indices {
      if named.contains(rows[index].id) {
        rows[index].hold()
        if [.deleting, .deleted].contains(rows[index].state), context.files.exists(rows[index].id) {
          rows[index].state = .pending
          rows[index].deleted = nil
          outcome.restored.append(rows[index].id)
        }
        continue
      }
      if let points = rows[index].releasePoints, !Self.stillHolds(points, retiredThen: rows[index].releaseRetired, snapshot: snapshot, retiredNow: retired) {
        rows[index].hold()
      }
      rows[index].release(at: now, points: snapshot, retired: retired)
    }
    outcome.restored += try await missingFromStorage(rows.filter { named.contains($0.id) && [.uploaded, .cached].contains($0.state) && context.files.exists($0.id) })
    for index in rows.indices where outcome.restored.contains(rows[index].id) {
      rows[index].state = .pending
      rows[index].deleted = nil
    }
    let settled = rows
    try await context.write { db in
      for row in settled { try SyncBlobTable.save(row, in: db) }
    }
    let candidates = rows.filter { $0.state == .uploaded && isAged($0, now: now) } + rows.filter { $0.state == .deleting && !named.contains($0.id) }
    outcome.deleted = try await deleteReleased(candidates, directory: directory)
    outcome.evicted = try await evict(rows.filter { !named.contains($0.id) && isEvictable($0, now: now) })
    guard !(outcome.deleted.isEmpty && outcome.restored.isEmpty && outcome.evicted.isEmpty) else { return }
    SyncBlobContext.logger.info(
      "Blob collection deleted=\(outcome.deleted.count, privacy: .public) restored=\(outcome.restored.count, privacy: .public) evicted=\(outcome.evicted.count, privacy: .public)"
    )
  }

  /// A release names streams by what this database had applied; once one of them is no longer applied here (adopted away, or this database continued as
  /// another replica) or has retired since, the change that dropped the blob may live on under another stream, so the release starts again.
  private static func stillHolds(_ points: [ReplicaID: Int64], retiredThen: Set<ReplicaID>, snapshot: [ReplicaID: Int64], retiredNow: Set<ReplicaID>) -> Bool {
    points.keys.allSatisfy { stream in snapshot[stream] != nil && (!retiredNow.contains(stream) || retiredThen.contains(stream)) }
  }

  private var retention: Int64 { context.configuration.blobRetention.milliseconds }

  private func isAged(_ row: SyncBlobRow, now: Int64) -> Bool {
    guard let released = row.released else { return false }
    return now - released >= retention && now - row.added >= retention
  }

  private func isEvictable(_ row: SyncBlobRow, now: Int64) -> Bool {
    switch row.state {
    case .cached: isAged(row, now: now)
    case .deleted: row.deleted.map { now - $0 >= retention } ?? false
    case .pending, .uploaded, .deleting: false
    }
  }

  /// One listing of every blob, so a held blob some record names is put again if storage lost it; a listing that omits a recent put only repeats that put.
  private func missingFromStorage(_ held: [SyncBlobRow]) async throws(SyncError) -> [BlobID] {
    guard !held.isEmpty else { return [] }
    let listing: [StorageObject]
    do {
      listing = try await context.provider.listAll(prefix: VaultPath.blobsPrefix)
    } catch {
      throw .storage(error)
    }
    var stored = Set<BlobID>()
    var parts: [BlobID: [Int: Set<Int>]] = [:]
    for object in listing {
      guard case .blobPart(let name, let part, let count) = VaultPath.classify(object.key), let id = BlobID(name) else { continue }
      parts[id, default: [:]][count, default: []].insert(part)
    }
    for (id, sets) in parts where sets.contains(where: { $0.value.count == $0.key }) { stored.insert(id) }
    return held.map(\.id).filter { !stored.contains($0) }
  }

  private func deleteReleased(_ candidates: [SyncBlobRow], directory: ReplicaDirectory) async throws(SyncError) -> [BlobID] {
    guard !candidates.isEmpty else { return [] }
    let deliverable = try await delivered(directory: directory)
    let doomed = candidates.filter { $0.state == .deleting || deliverable($0) }
    guard !doomed.isEmpty else { return [] }
    try await context.write { db in
      for var row in doomed where row.state != .deleting {
        row.state = .deleting
        try SyncBlobTable.save(row, in: db)
      }
    }
    let keys = doomed.flatMap(\.partKeys)
    for start in stride(from: 0, to: keys.count, by: SyncCompactor.deleteBatch) {
      do {
        try await context.provider.delete(Array(keys[start..<min(start + SyncCompactor.deleteBatch, keys.count)]))
      } catch {
        throw .storage(error)
      }
    }
    let millis = context.millis
    try await context.write { db in
      for row in doomed {
        guard var current = try SyncBlobTable.load(row.id, in: db), current.state == .deleting else { continue }
        current.state = .deleted
        current.deleted = millis
        try SyncBlobTable.save(current, in: db)
      }
    }
    return doomed.map(\.id)
  }

  private func replicaDirectory() async throws(SyncError) -> ReplicaDirectory {
    do {
      return try await lifecycle.directory()
    } catch {
      throw SyncError(converting: error)
    }
  }

  /// Whether every active replica has published that it applied a row's release points, retired streams included, and this database has applied that
  /// replica up to its manifest's head. A replica without a readable manifest stops every removal.
  private func delivered(directory: ReplicaDirectory) async throws(SyncError) -> @Sendable (SyncBlobRow) -> Bool {
    let replica = replica
    let applied = try await context.read { try SyncAppliedTable.points(excluding: replica, in: $0).mapValues(\.last) }
    var manifests: [ReplicaID: ReplicaManifest] = [:]
    for entry in directory.replicas where entry.state == .active && entry.replica != replica {
      guard let manifest = await manifest(of: entry.replica), (applied[entry.replica] ?? 0) >= (manifest.head?.last ?? 0) else { return { _ in false } }
      manifests[entry.replica] = manifest
    }
    let found = manifests
    return { row in
      guard let points = row.releasePoints else { return false }
      return found.allSatisfy { peer, manifest in
        points.allSatisfy { stream, last in stream == peer || (manifest.applied[stream]?.last ?? 0) >= last }
      }
    }
  }

  private func manifest(of peer: ReplicaID) async -> ReplicaManifest? {
    let key = VaultPath.manifest(peer)
    guard let data = try? await context.provider.get(key) else { return nil }
    let ring = context.ring
    return try? ReplicaManifestCodec.open(data, at: key, vault: context.vault) { ring.key($0) }
  }

  private func evict(_ rows: [SyncBlobRow]) async throws(SyncError) -> [BlobID] {
    guard !rows.isEmpty else { return [] }
    let ids = rows.map(\.id)
    try await context.write { db in
      for id in ids { try SyncBlobTable.remove(id, in: db) }
    }
    for id in ids { context.files.remove(id) }
    return ids
  }
}
