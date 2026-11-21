import Foundation
import OSLog
import ShadowCore
import ShadowSync

enum SyncMoveFollowStep: Sendable, Equatable, CaseIterable {
  case journaled
  case followed
  case locationSaved
}

/// Follows a move another device made: after `SyncEngine.download()` reports `moved`, or `upload()` throws `vaultMoved`, this continues the database as a new
/// replica at the notice's location. Changes the moved base may lack, sent or not, are relayed first and uploaded from the new replica. Run it while no
/// engine syncs the vault, and again after any failure or restart until it returns; until the new location is saved it can be pointed at another reach of
/// that location or abandoned, and `SyncEngine.forgetMove()` then lets the device stay at the old location.
public struct SyncMoveFollower: Sendable {
  private static let logger = Logger(category: "SyncMoveFollower")

  private let engine: SyncEngine
  private let source: SyncLocation
  private let target: SyncLocation
  private let targetProvider: any StorageProvider
  private let locations: SyncLocationStore
  private let journal: SyncMoveJournalStore
  private let checkpoint: @Sendable (SyncMoveFollowStep) throws(SyncMoveError) -> Void

  /// `target` is the notice's location as this device reaches it: its own folder or credentials and its own account binding.
  public init(engine: SyncEngine, source: SyncLocation, target: SyncLocation, targetProvider: any StorageProvider, locations: SyncLocationStore) {
    self.init(engine: engine, source: source, target: target, targetProvider: targetProvider, locations: locations) { _ throws(SyncMoveError) in }
  }

  init(
    engine: SyncEngine, source: SyncLocation, target: SyncLocation, targetProvider: any StorageProvider, locations: SyncLocationStore,
    checkpoint: @escaping @Sendable (SyncMoveFollowStep) throws(SyncMoveError) -> Void
  ) {
    self.engine = engine
    self.source = source
    self.target = target
    self.targetProvider = targetProvider
    self.locations = locations
    journal = SyncMoveJournalStore(beside: locations)
    self.checkpoint = checkpoint
  }

  public func run(_ notice: VaultMoveNotice) async throws(SyncMoveError) -> SyncMoveOutcome {
    if let closed = try close() { return closed }
    guard target.vault == source.vault else { throw .vaultMismatch(expected: source.vault, found: target.vault) }
    guard target.settings != source.settings else { throw .sameLocation }
    if let named = notice.targetLocation?.kind, named != target.kind { throw .targetKindMismatch(expected: named, found: target.kind) }
    let from = try await begin(notice)
    do {
      _ = try await engine.followMove(notice, from: from, admitting: targetProvider.capabilities.classPolicy)
    } catch {
      throw .sync(error)
    }
    try checkpoint(.followed)
    do {
      try locations.save(target)
    } catch {
      throw .location(error)
    }
    try checkpoint(.locationSaved)
    try journal.clear()
    Self.logger.info("Followed a vault move kind=\(target.kind.rawValue, privacy: .public)")
    return .moved(replica: engine.replica, location: target)
  }

  /// Closes a follow whose new location was saved before its journal was cleared, which needs no notice; nil when there is none.
  public func close() throws(SyncMoveError) -> SyncMoveOutcome? {
    guard case .following(_, let saved)? = try journal.load(), saved == target, try SyncMoveJournalStore.isSaved(target, in: locations) else { return nil }
    try journal.clear()
    return .moved(replica: engine.replica, location: target)
  }

  /// Forgets a follow whose new location was not saved yet. The database may already be a new replica; it stays one wherever it syncs next.
  public func abandon() throws(SyncMoveError) {
    switch try journal.load() {
    case nil, .following?: try journal.clear()
    case let other?: throw .moveInProgress(other)
    }
  }

  /// A follow saved for another target is pointed at this one, keeping its origin, as long as that target was never saved.
  private func begin(_ notice: VaultMoveNotice) async throws(SyncMoveError) -> ReplicaID {
    let from: ReplicaID
    switch try journal.load() {
    case .following(let saved, let earlier)? where earlier == target: return saved
    case .following(let saved, let earlier)?:
      guard try !SyncMoveJournalStore.isSaved(earlier, in: locations) else { throw .moveInProgress(.following(from: saved, target: earlier)) }
      from = saved
    case let other?: throw .moveInProgress(other)
    case nil: from = engine.replica
    }
    try await requireMovedVault(notice)
    try journal.save(.following(from: from, target: target))
    try checkpoint(.journaled)
    return from
  }

  /// The mover puts the hint and its base before its notice. A later compaction of the mover replaces that base, so any complete base of it counts.
  private func requireMovedVault(_ notice: VaultMoveNotice) async throws(SyncMoveError) {
    let data: Data
    let parts: [StorageObject]
    do {
      data = try await targetProvider.get(VaultPath.hint)
      parts = try await targetProvider.listAll(prefix: VaultPath.basePrefix(notice.to))
    } catch {
      guard case .notFound = error else { throw .target(error) }
      throw .targetMissingVault
    }
    guard let hint = try? VaultHint(decoding: data) else { throw .targetMissingVault }
    guard hint.vault == target.vault else { throw .vaultMismatch(expected: target.vault, found: hint.vault) }
    var bases: [StreamPoint: (parts: Int, listed: Set<Int>)] = [:]
    for object in parts {
      guard case .basePart(notice.to, let upTo, let tag, let part, let count) = VaultPath.classify(object.key) else { continue }
      let point = StreamPoint(last: upTo, tag: tag)
      guard bases[point].map({ $0.parts == count }) ?? true else { continue }
      bases[point, default: (count, [])].listed.insert(part)
    }
    guard bases.values.contains(where: { $0.listed.count == $0.parts }) else { throw .targetMissingVault }
  }
}
