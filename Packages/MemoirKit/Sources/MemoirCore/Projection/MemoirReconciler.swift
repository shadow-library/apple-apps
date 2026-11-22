import CryptoKit
import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Synchronization

/// Keeps the `mm_derived_*` tables equal to a full replay of the command log walked to today, without replaying the whole log on every merge.
///
/// A merged, changed or purged command is placed by its clock (`mm_local_replay_command`); the replay resumes from the latest checkpoint strictly before
/// the earliest such place (`mm_local_replay_checkpoint`), extends it with every command after it, saves a checkpoint where a day closes (the last
/// `recentCheckpoints` and the last of every month are kept), and only then walks a copy to the horizon for the view, so a checkpoint never holds a day
/// the horizon alone closed. Any change of layout, schema, ruleset or app version drops the checkpoints and rebuilds everything. A command this build
/// cannot read halts replay, and the hero row says the app needs an update.
public struct MemoirReconciler: StoreReconciler {
  /// Raise it when replay's meaning changes, so every checkpoint and derived row is rebuilt.
  public static let replayVersion = 2
  public static let recentCheckpoints = 7
  static let layoutTable = "mm_derived_layout"
  static let fingerprintDomain = "com.shadow.library.memoircore.projection"

  public let registry: SchemaRegistry
  public let fingerprint: String
  private let horizon: Horizon
  private let cache = CheckpointCache()

  private enum Horizon {
    case given(@Sendable () -> IssueStamp?)
    case accountZone(now: @Sendable () -> Date, device: @Sendable () -> TimeZone)
  }

  /// `appVersion` must change with every build that can change replay, derived rows or their encoding: pass the build number (`CFBundleVersion`), never
  /// the marketing version, which two builds share. `horizon` is the local day as `IssueClock.stamp` gives it; nil leaves the view at the latest command's
  /// day. An app passes `now` and `deviceZone` instead, so the horizon follows the account's zone in force.
  public init(registry: SchemaRegistry = MemoirSchema.mainRegistry, appVersion: String, horizon: @escaping @Sendable () -> IssueStamp? = { nil })
    throws(ReplayCheckpointError)
  {
    try self.init(registry: registry, appVersion: appVersion, horizon: .given(horizon))
  }

  /// The horizon is `now` in the clock `AccountZone` gives for the replayed state: the account's zone in force on its open day, the staged one once
  /// that day has passed, and `deviceZone` only before any zone is set. `deviceZone` is the app's `{ TimeZone.current }`.
  public init(
    registry: SchemaRegistry = MemoirSchema.mainRegistry, appVersion: String, now: @escaping @Sendable () -> Date,
    deviceZone: @escaping @Sendable () -> TimeZone
  ) throws(ReplayCheckpointError) {
    try self.init(registry: registry, appVersion: appVersion, horizon: .accountZone(now: now, device: deviceZone))
  }

  private init(registry: SchemaRegistry, appVersion: String, horizon: Horizon) throws(ReplayCheckpointError) {
    self.registry = registry
    self.horizon = horizon
    let parts =
      [
        "\(ReplayCheckpoint.formatVersion)", "\(ReplayState.codingVersion)", "\(Self.replayVersion)", "\(registry.version)",
        registry.canonicalDescription().base64EncodedString(), "\(Ruleset.current.version)", try Self.canonicalJSON(Ruleset.current).base64EncodedString(),
        appVersion,
      ] + DerivedRows.definitions + ReplayCommandIndex.definitions + [ReplayCheckpointTable.definition]
    var hash = SHA256()
    hash.update(data: Data(Self.fingerprintDomain.utf8))
    for part in parts { hash.update(data: Data("\n\(part.utf8.count):\(part)".utf8)) }
    fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// `JSONEncoder` orders keys differently from one process to the next, so anything hashed or compared as bytes goes through `CanonicalJSON`.
  static func canonicalJSON(_ value: some Encodable) throws(ReplayCheckpointError) -> Data {
    let encoded: Data
    do {
      encoded = try JSONEncoder().encode(value)
    } catch {
      throw .unencodable(String(describing: error))
    }
    do throws(CanonicalJSONError) {
      return CanonicalJSON.encode(try CanonicalJSON.decode(encoded, mode: .lenient))
    } catch {
      throw .unencodable(error.errorDescription ?? error.code)
    }
  }

  public var tables: [String] { DerivedRows.tables }

  public func reconcile(_ touched: [EntityRef], origin _: ChangeOrigin, in database: Database) throws {
    try MemoirProjectionSQL.run {
      guard !(try layOut(in: database)), try ReplayCommandIndex.exists(in: database) else { return try rebuildAll(in: database) }
      let source = ReadTransaction(database: database, registry: registry)
      var earliest: ReplayPosition?
      for ref in touched where ref.kind == MemoirKind.command.entityKind {
        let indexed = try ReplayCommandIndex.clock(of: ref, in: database)
        let current = Replay.command(ref, in: try source.state(of: ref))?.clock
        guard indexed != current else { continue }
        try ReplayCommandIndex.record(ref, clock: current, in: database)
        for clock in [indexed, current].compactMap(\.self) {
          let position = ReplayPosition(clock: clock, ref: ref)
          earliest = min(earliest ?? position, position)
        }
      }
      guard let earliest else { return }
      try project(changedAt: earliest, in: database)
    }
  }

  /// The vault scope was cleared: everything is rebuilt from what the store holds now.
  public func reset(in database: Database) throws {
    try rebuild(in: database)
  }

  public func rebuild(in database: Database) throws(StoreError) {
    try MemoirProjectionSQL.run {
      try layOut(in: database)
      try rebuildAll(in: database)
    }
  }

  /// Rewrites the view for the current horizon, resuming from the latest checkpoint; call it at launch and whenever the local day changes.
  public func refresh(in database: Database) throws(StoreError) {
    try MemoirProjectionSQL.run {
      guard !(try layOut(in: database)), try ReplayCommandIndex.exists(in: database) else { return try rebuildAll(in: database) }
      try project(changedAt: nil, in: database)
    }
  }

  public func refresh(_ store: VaultStore) async throws(StoreError) {
    let reconciler = self
    try await store.write { transaction in try reconciler.refresh(in: transaction.database) }
  }

  @discardableResult
  private func layOut(in database: Database) throws -> Bool {
    try database.execute(sql: "CREATE TABLE IF NOT EXISTS \(Self.layoutTable) (slot INTEGER PRIMARY KEY CHECK (slot = 1), fingerprint TEXT NOT NULL) STRICT")
    guard try String.fetchOne(database, sql: "SELECT fingerprint FROM \(Self.layoutTable)") != fingerprint else { return false }
    for table in DerivedRows.tables { try database.execute(sql: "DROP TABLE IF EXISTS \(table)") }
    try ReplayCheckpointTable.drop(in: database)
    try ReplayCommandIndex.drop(in: database)
    for definition in DerivedRows.definitions { try database.execute(sql: definition) }
    try database.execute(sql: "INSERT OR REPLACE INTO \(Self.layoutTable) (slot, fingerprint) VALUES (1, ?)", arguments: [fingerprint])
    return true
  }

  private func rebuildAll(in database: Database) throws {
    try ReplayCheckpointTable.drop(in: database)
    let commands = try Replay.commands(in: ReadTransaction(database: database, registry: registry))
    try ReplayCommandIndex.replace(with: commands, in: database)
    try run(from: .initial, with: commands, in: database)
  }

  /// `changedAt` is the earliest place a command appeared or disappeared; nil only rewrites the view.
  private func project(changedAt change: ReplayPosition?, in database: Database) throws {
    if let change { try ReplayCheckpointTable.delete(atOrAfter: change, in: database) }
    let start = try resumption(in: database)
    let source = ReadTransaction(database: database, registry: registry)
    let commands = try ReplayCommandIndex.refs(after: start.position, in: database).compactMap { ref in Replay.command(ref, in: try source.state(of: ref)) }
    try run(from: start, with: commands, in: database)
  }

  /// The latest checkpoint this build can resume from; a stale, tampered or unreadable one is deleted on the way down, and none leaves the initial state.
  private func resumption(in database: Database) throws -> ReplayState {
    for entry in try ReplayCheckpointTable.entries(in: database) {
      if entry.stamp == fingerprint, let state = cache.state(for: entry.digest) { return state }
      guard let checkpoint = try ReplayCheckpointTable.checkpoint(at: entry, in: database) else { continue }
      do throws(ReplayCheckpointError) {
        let state = try checkpoint.state(expecting: fingerprint)
        cache.keep(state, for: entry.digest)
        return state
      } catch {
        try ReplayCheckpointTable.delete(entry.position, in: database)
      }
    }
    return .initial
  }

  private func horizon(for state: ReplayState) -> IssueStamp? {
    switch horizon {
    case .given(let stamp): stamp()
    case .accountZone(let now, let device): AccountZone(state).horizon(at: now(), device: device())
    }
  }

  private func run(from start: ReplayState, with commands: [ReplayCommand], in database: Database) throws {
    var retention = CheckpointRetention(recent: Self.recentCheckpoints, stamp: fingerprint, cache: cache)
    var state = start
    for command in Replay.ordered(commands) {
      let step = try Replay.step(command, to: &state) { (boundary: ReplayState) throws in try retention.offer(boundary, in: database) }
      guard step != .outOfOrder else { throw StoreError.corruptStore("the replay command index placed \(command.ref) before its checkpoint") }
    }
    try retention.finish(in: database)
    try ReplayCheckpointTable.prune(keepingRecent: Self.recentCheckpoints, in: database)
    var view = state
    if let horizon = horizon(for: state) { Replay.walk(&view, through: horizon) }
    try DerivedRows(view).write(in: database)
  }
}

/// The checkpoints one run saves: the latest of each month as soon as the next month begins, and the latest `recent` when the run ends, so a run over a
/// year of history holds a handful of states in memory and encodes only those it keeps.
private struct CheckpointRetention {
  let recent: Int
  let stamp: String
  let cache: CheckpointCache
  private var latest: [ReplayState] = []
  private var monthEnd: ReplayState?
  private var written: [ReplayPosition: String] = [:]

  init(recent: Int, stamp: String, cache: CheckpointCache) {
    self.recent = recent
    self.stamp = stamp
    self.cache = cache
  }

  mutating func offer(_ boundary: ReplayState, in database: Database) throws {
    if let previous = monthEnd, let ended = previous.openDay, let day = boundary.openDay, (ended.year, ended.month) != (day.year, day.month) {
      try write(previous, in: database)
    }
    monthEnd = boundary
    latest.append(boundary)
    if latest.count > recent { latest.removeFirst() }
  }

  /// The newest checkpoint is the one the next merge most likely resumes from, so it stays decoded.
  mutating func finish(in database: Database) throws {
    if let monthEnd { try write(monthEnd, in: database) }
    for state in latest { try write(state, in: database) }
    if let newest = latest.last, let position = newest.position, let digest = written[position] { cache.keep(newest, for: digest) }
  }

  private mutating func write(_ state: ReplayState, in database: Database) throws {
    guard let position = state.position, written[position] == nil else { return }
    let checkpoint = try ReplayCheckpoint(state, stamp: stamp)
    try ReplayCheckpointTable.write(checkpoint, in: database)
    written[position] = checkpoint.digest
  }
}

/// Decoded checkpoints by digest, which binds a body to its stamp and position, so a hit is the state that row holds whichever store or transaction asks.
private final class CheckpointCache: Sendable {
  private static let capacity = 2
  private let entries = Mutex<[(digest: String, state: ReplayState)]>([])

  func state(for digest: String) -> ReplayState? {
    entries.withLock { entries in entries.first { $0.digest == digest }?.state }
  }

  func keep(_ state: ReplayState, for digest: String) {
    entries.withLock { entries in
      entries.removeAll { $0.digest == digest }
      entries.insert((digest, state), at: 0)
      if entries.count > Self.capacity { entries.removeLast() }
    }
  }
}
