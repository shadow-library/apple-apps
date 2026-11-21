import CryptoKit
import Foundation
import OSLog
import ShadowCore
import ShadowStore
import ShadowSync

enum SyncMoveStep: Sendable, Equatable, CaseIterable {
  case journaled
  case settled
  case reminted
  case sealed
  case blobsCopied
  case partsPut
  case hintPut
  case verified
  case recorded
  case noticePut
  case locationSaved
}

/// Moves the vault from `source` to `target` on this device. Run it only while no engine syncs the vault, and again after any failure or restart until it
/// returns: every step can be repeated, and once the new location is saved a run with an attachment to it only closes the move. Before the move re-mints, it
/// syncs once at the old location, so unsent changes pass the upload checks there; after that the old location gains only the move notice. Nothing is
/// deleted anywhere. Without put-if-absent at the old location, two devices moving at once can both see their own notice and both finish.
public struct SyncMover: Sendable {
  private static let logger = Logger(category: "SyncMover")

  private let engine: SyncEngine
  private let ring: KeyRing
  private let source: SyncLocation
  private let sourceProvider: any StorageProvider
  private let target: SyncLocation
  private let targetProvider: any StorageProvider
  private let locations: SyncLocationStore
  private let journal: SyncMoveJournalStore
  private let wallClock: @Sendable () -> Date
  private let checkpoint: @Sendable (SyncMoveStep) throws(SyncMoveError) -> Void

  /// `engine` is the started engine of `attachment`; `target` names the same vault and the account binding of the new location.
  public init(
    engine: SyncEngine, attachment: SyncAttachment, target: SyncLocation, targetProvider: any StorageProvider, locations: SyncLocationStore,
    wallClock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(
      engine: engine, ring: attachment.ring, source: attachment.location, sourceProvider: attachment.provider, target: target, targetProvider: targetProvider,
      locations: locations, wallClock: wallClock)
  }

  init(
    engine: SyncEngine, ring: KeyRing, source: SyncLocation, sourceProvider: any StorageProvider, target: SyncLocation, targetProvider: any StorageProvider,
    locations: SyncLocationStore, wallClock: @escaping @Sendable () -> Date = { Date() },
    checkpoint: @escaping @Sendable (SyncMoveStep) throws(SyncMoveError) -> Void = { _ throws(SyncMoveError) in }
  ) {
    self.engine = engine
    self.ring = ring
    self.source = source
    self.sourceProvider = sourceProvider
    self.target = target
    self.targetProvider = targetProvider
    self.locations = locations
    journal = SyncMoveJournalStore(beside: locations)
    self.wallClock = wallClock
    self.checkpoint = checkpoint
  }

  public func run() async throws(SyncMoveError) -> SyncMoveOutcome {
    if let finished = try finishedEarlier() { return finished }
    guard target.vault == source.vault else { throw .vaultMismatch(expected: source.vault, found: target.vault) }
    guard target.settings != source.settings else { throw .sameLocation }
    let from = try await begin()
    let earlier = try await sync { () async throws(SyncError) in try await engine.moveRemint(of: from) }
    if let notice = try await readNotice() {
      guard let earlier, notice.from == earlier.retired else { return try supersede(by: notice) }
      return try finish()
    }
    let moved: SyncMoveRemint
    if let earlier {
      moved = earlier
    } else {
      if let winner = try await settleSource() { return try supersede(by: winner) }
      try checkpoint(.settled)
      moved = try await sync { () async throws(SyncError) in try await engine.moveOut(from: from) }
      try checkpoint(.reminted)
    }
    let base = try await sync { () async throws(SyncError) in try await engine.sealMoveBase(for: targetProvider.capabilities, partial: moved.partial) }
    try checkpoint(.sealed)
    let blobs = try await copyBlobs()
    try checkpoint(.blobsCopied)
    for part in base.parts { try await putTarget(part.key, data: part.data) }
    try checkpoint(.partsPut)
    try await putHint()
    try checkpoint(.hintPut)
    try await verify(base, blobs: blobs)
    try checkpoint(.verified)
    try await sync { () async throws(SyncError) in try await engine.recordMoveBase(base) }
    try checkpoint(.recorded)
    let notice = VaultMoveNotice(
      from: moved.retired, to: base.replica, base: base.reference, frontier: base.frontier, target: VaultMoveNotice.target(of: target), movedMillis: millis)
    if let winner = try await putNotice(notice, sealedLike: base) { return try supersede(by: winner) }
    try checkpoint(.noticePut)
    return try finish()
  }

  /// Gives up a move whose notice is not written yet. The database stays the new replica it may have become and syncs on at the old location; what the
  /// move wrote at the new location stays there, so that location no longer counts as empty for a later move.
  public func abandon() async throws(SyncMoveError) {
    switch try journal.load() {
    case nil: return
    case .movingOut(let from, let saved)? where saved == target:
      let earlier = try await sync { () async throws(SyncError) in try await engine.moveRemint(of: from) }
      if let earlier, let notice = try await readNotice(), notice.from == earlier.retired { throw .alreadyMoved(notice) }
      try journal.clear()
    case let other?: throw .moveInProgress(other)
    }
  }

  /// A move whose new location was saved before its journal was cleared; the attachment may name the new location by now.
  private func finishedEarlier() throws(SyncMoveError) -> SyncMoveOutcome? {
    guard case .movingOut(_, let saved)? = try journal.load(), saved == target, try SyncMoveJournalStore.isSaved(target, in: locations) else { return nil }
    try journal.clear()
    return .moved(replica: engine.replica, location: target)
  }

  /// Returns the notice that stopped the sync, when another device moved the vault meanwhile.
  private func settleSource() async throws(SyncMoveError) -> VaultMoveNotice? {
    let upload: SyncUploadOutcome
    do {
      upload = try await engine.sync().upload
    } catch {
      guard case .vaultMoved = error else { throw .sync(error) }
      guard let notice = try await readNotice() else { throw .sync(error) }
      return notice
    }
    switch upload {
    case .uploaded, .nothingToUpload: return nil
    case .awaitingKey(let floor): throw .sync(.awaitingKey(floor: floor))
    case .postponed: throw .sourceNotSettled
    }
  }

  /// A fresh move checks, before it writes anything, that nobody moved the vault already, that the target holds no vault and that every blob fits there.
  private func begin() async throws(SyncMoveError) -> ReplicaID {
    switch try journal.load() {
    case .movingOut(let from, let saved)? where saved == target: return from
    case let other?: throw .moveInProgress(other)
    case nil: break
    }
    if let notice = try await readNotice() { throw .alreadyMoved(notice) }
    try await requireEmptyTarget()
    _ = try await listBlobs()
    let from = engine.replica
    try journal.save(.movingOut(from: from, target: target))
    try checkpoint(.journaled)
    Self.logger.info("Started moving a vault kind=\(target.kind.rawValue, privacy: .public)")
    return from
  }

  private func finish() throws(SyncMoveError) -> SyncMoveOutcome {
    do {
      try locations.save(target)
    } catch {
      throw .location(error)
    }
    try checkpoint(.locationSaved)
    try journal.clear()
    Self.logger.info("Moved a vault kind=\(target.kind.rawValue, privacy: .public)")
    return .moved(replica: engine.replica, location: target)
  }

  private func supersede(by notice: VaultMoveNotice) throws(SyncMoveError) -> SyncMoveOutcome {
    try journal.clear()
    Self.logger.info("Another device moved the vault first")
    return .superseded(notice)
  }

  private func readNotice() async throws(SyncMoveError) -> VaultMoveNotice? {
    let data: Data
    do {
      data = try await sourceProvider.get(VaultPath.moveNotice)
    } catch {
      guard case .notFound = error else { throw .source(error) }
      return nil
    }
    do {
      return try VaultMoveNoticeCodec.open(data, vault: source.vault) { ring.key($0) }
    } catch {
      throw .noticeUnreadable
    }
  }

  private func requireEmptyTarget() async throws(SyncMoveError) {
    var cursor: ListCursor?
    repeat {
      let page: ListPage
      do {
        page = try await targetProvider.list(prefix: "", after: cursor)
      } catch {
        throw .target(error)
      }
      guard page.next == nil || page.next != cursor else { throw .target(.underlying("list cursor did not advance")) }
      guard page.objects.allSatisfy({ VaultPath.classify($0.key) == .unknown }) else { throw .targetHoldsVault }
      cursor = page.next
    } while cursor != nil
  }

  private func listBlobs() async throws(SyncMoveError) -> [StorageObject] {
    let objects: [StorageObject]
    do {
      objects = try await sourceProvider.listAll(prefix: "blobs/")
    } catch {
      throw .source(error)
    }
    let blobs = objects.filter { if case .blobPart = VaultPath.classify($0.key) { true } else { false } }
    let limit = targetProvider.capabilities.maxObjectBytes
    if let large = blobs.first(where: { $0.size > limit }) { throw .blobTooLarge(large.key, size: large.size, limit: limit) }
    return blobs
  }

  /// Blobs are named by a keyed hash of their content and sealed for their path, so the same bytes are valid at the same name in the new location.
  private func copyBlobs() async throws(SyncMoveError) -> [ObjectKey: SHA256.Digest] {
    var digests: [ObjectKey: SHA256.Digest] = [:]
    for blob in try await listBlobs() {
      let data: Data
      do {
        data = try await sourceProvider.get(blob.key)
      } catch {
        throw .source(error)
      }
      guard data.count <= targetProvider.capabilities.maxObjectBytes else { throw .blobTooLarge(blob.key, size: data.count, limit: targetProvider.capabilities.maxObjectBytes) }
      try await putTarget(blob.key, data: data)
      digests[blob.key] = SHA256.hash(data: data)
    }
    return digests
  }

  /// Overwrites, so a copy that failed verification is replaced when the move runs again; only this replica writes under its prefix.
  private func putTarget(_ key: ObjectKey, data: Data) async throws(SyncMoveError) {
    do {
      _ = try await targetProvider.put(key, data: data, condition: .overwrite)
    } catch {
      throw .target(error)
    }
  }

  private func putHint() async throws(SyncMoveError) {
    if try await targetHint() == nil {
      let condition: PutCondition = targetProvider.capabilities.supportsPutIfAbsent ? .ifAbsent : .overwrite
      do {
        _ = try await targetProvider.put(VaultPath.hint, data: VaultHint(vault: target.vault).encoded(), condition: condition)
      } catch {
        guard case .alreadyExists = error else { throw .target(error) }
      }
    }
    try await requireTargetHint()
  }

  private func requireTargetHint() async throws(SyncMoveError) {
    guard let hint = try await targetHint() else { throw .verificationFailed(VaultPath.hint) }
    guard hint == target.vault else { throw .targetHoldsVault }
  }

  private func targetHint() async throws(SyncMoveError) -> VaultID? {
    let data: Data
    do {
      data = try await targetProvider.get(VaultPath.hint)
    } catch {
      guard case .notFound = error else { throw .target(error) }
      return nil
    }
    guard let hint = try? VaultHint(decoding: data) else { throw .targetHoldsVault }
    return hint.vault
  }

  /// Every part and blob is read back, compared with what was put and opened with the ring, and the parts are assembled, which checks the base's keyed tag.
  private func verify(_ base: SyncMoveBase, blobs: [ObjectKey: SHA256.Digest]) async throws(SyncMoveError) {
    let vault = target.vault
    let ring = ring
    var parts: [BasePart] = []
    for part in base.parts {
      let data = try await readBack(part.key, expecting: SHA256.hash(data: part.data))
      guard let opened = try? BaseCodec.openPart(data, at: part.key, vault: vault, keys: { ring.key($0) }) else { throw .verificationFailed(part.key) }
      parts.append(opened)
    }
    guard let file = try? BaseCodec.assemble(parts, keys: { ring.key($0) }), file.header.replica == base.replica, file.header.upTo == base.point.last,
      parts.first?.tag == base.point.tag
    else { throw .verificationFailed(base.parts[0].key) }
    for (key, digest) in blobs.sorted(by: { $0.key < $1.key }) {
      let data = try await readBack(key, expecting: digest)
      guard (try? VaultFile.open(data, path: key.rawValue, vault: vault, keys: { ring.key($0) })) != nil else { throw .verificationFailed(key) }
    }
    try await requireTargetHint()
  }

  private func readBack(_ key: ObjectKey, expecting digest: SHA256.Digest) async throws(SyncMoveError) -> Data {
    let data: Data
    do {
      data = try await targetProvider.get(key)
    } catch {
      guard case .notFound = error else { throw .target(error) }
      throw .verificationFailed(key)
    }
    guard SHA256.hash(data: data) == digest else { throw .verificationFailed(key) }
    return data
  }

  /// Returns the notice another device put first, or nil when this one stands. Without put-if-absent the notice read back after the put decides.
  private func putNotice(_ notice: VaultMoveNotice, sealedLike base: SyncMoveBase) async throws(SyncMoveError) -> VaultMoveNotice? {
    guard let sealed = base.parts.first?.data, let keyID = try? VaultFile.header(of: sealed).keyID, let key = ring.key(keyID) else {
      throw .sync(.awaitingKey(floor: nil))
    }
    let data: Data
    do {
      data = try VaultMoveNoticeCodec.seal(notice, vault: source.vault, with: key)
    } catch {
      throw .sync(.replicaFile(error))
    }
    let atomic = sourceProvider.capabilities.supportsPutIfAbsent
    do {
      _ = try await sourceProvider.put(VaultPath.moveNotice, data: data, condition: atomic ? .ifAbsent : .overwrite)
    } catch {
      guard case .alreadyExists = error else { throw .source(error) }
    }
    guard let stored = try await readNotice() else { throw .source(.notFound(VaultPath.moveNotice)) }
    return stored.from == notice.from ? nil : stored
  }

  private var millis: Int64 {
    max(0, Int64((wallClock().timeIntervalSince1970 * 1_000).rounded(.down)))
  }

  private func sync<T>(_ body: () async throws(SyncError) -> T) async throws(SyncMoveError) -> T {
    do {
      return try await body()
    } catch {
      throw .sync(error)
    }
  }
}
