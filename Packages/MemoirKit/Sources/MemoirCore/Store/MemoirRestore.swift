import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowSync

public enum MemoirRestoreError: DomainFailure {
  /// One of the three stores holds data already; a restore never merges into or replaces a vault.
  case vaultNotEmpty
  /// An earlier restore committed some stores but not the main one; only erasing the vault clears it.
  case unfinished
  case storeMissing(MemoirStoreKind)
  /// Written by a newer build of Memoir, whose records this build may not read.
  case registryTooNew(MemoirStoreKind, found: Int, supported: Int)
  case registryUnknown(MemoirStoreKind, found: Int)
  /// A command names a ruleset this build does not have.
  case rulesetTooNew(Int)
  case refused(String)
  case receipt(String)
  case blob(BlobError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .vaultNotEmpty: "memoir_restore.vault_not_empty"
    case .unfinished: "memoir_restore.unfinished"
    case .storeMissing: "memoir_restore.store_missing"
    case .registryTooNew: "memoir_restore.registry_too_new"
    case .registryUnknown: "memoir_restore.registry_unknown"
    case .rulesetTooNew: "memoir_restore.ruleset_too_new"
    case .refused: "memoir_restore.refused"
    case .receipt: "memoir_restore.receipt"
    case .blob(let error): error.code
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .vaultNotEmpty: "The vault already holds data, so nothing was restored."
    case .unfinished: "An earlier restore did not finish; the vault must be erased before restoring again."
    case .storeMissing(let store): "The export has no \(store.rawValue) store."
    case .registryTooNew(let store, let found, let supported):
      "The \(store.rawValue) store was exported at registry version \(found); this build reads up to version \(supported)."
    case .registryUnknown(let store, let found): "The \(store.rawValue) store names registry version \(found), which no build wrote."
    case .rulesetTooNew(let version): "A command follows ruleset version \(version), which this build does not have."
    case .refused(let reason), .receipt(let reason): reason
    case .blob(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  public var storeFailure: StoreError? {
    guard case .store(let error) = self else { return nil }
    return error
  }
}

/// What an export holds, ready to restore: each store's entities as stored, the receipt images (each a file this device already holds privately, named
/// by the blob id its receipt records) and this device's weekly review answers.
public struct MemoirRestoreContents: Sendable {
  /// `entities` are written in the order given and stamped with this store's clocks, so an appended kind's items must come in the order of their clocks
  /// where they were exported: replay orders commands by that clock, not by key.
  public struct Store: Sendable {
    public let registryVersion: Int
    public let entities: [ImportedEntity]

    public init(registryVersion: Int, entities: [ImportedEntity]) {
      self.registryVersion = registryVersion
      self.entities = entities
    }
  }

  public struct ReceiptImage: Sendable {
    public let blob: BlobID
    public let file: URL

    public init(blob: BlobID, file: URL) {
      self.blob = blob
      self.file = file
    }
  }

  public let stores: [MemoirStoreKind: Store]
  public let receiptImages: [ReceiptImage]
  public let weeklyReviews: [LocalDate: ReviewAnswers]

  public init(stores: [MemoirStoreKind: Store], receiptImages: [ReceiptImage], weeklyReviews: [LocalDate: ReviewAnswers]) {
    self.stores = stores
    self.receiptImages = receiptImages
    self.weeklyReviews = weeklyReviews
  }
}

/// Puts an export back into an empty vault, and only there: the owner's copy after a lost device or a reinstall, never a merge. Each store's entities go
/// in exactly as exported through `VaultStore.importEntities`, the one write that bypasses the typed records, so keys, fields, commands and revisions
/// with their generations come back as they were; sync then uploads them as this device's changes, and the replay projection derives the hero again.
/// The stores import together and commit main last, so a failure before the commits leaves all three empty and onboarding sees no data until everything
/// is in. A failure between the commits (main's own commit, or the app stopped) leaves `RestorePending` beside the other stores' data: `isUnfinished` then
/// holds, and only erasing the vault clears it.
public enum MemoirRestore {
  /// A store's own data: every kind its registry declares except sync's bookkeeping, which is never exported.
  public static func dataKinds(of store: MemoirStoreKind) -> Set<EntityKind> {
    Set(store.registry.schemas.map(\.kind)).subtracting(SyncKernelSchema.entities.map(\.kind))
  }

  /// No store holds any of its data: no record, command, tombstone or unreadable record of a data kind.
  public static func isEmpty(_ stores: MemoirStores) async throws(StoreError) -> Bool {
    for kind in MemoirStoreKind.allCases {
      let kinds = dataKinds(of: kind)
      if try await stores.store(kind).read({ transaction in try transaction.holdsEntities(ofKinds: kinds) }) { return false }
    }
    return true
  }

  /// A restore committed the health or activity store and not the main one, which commits last, as when main's commit failed or the app stopped between
  /// the commits; what main holds says nothing about it.
  public static func isUnfinished(_ stores: MemoirStores) async throws(StoreError) -> Bool {
    guard try await isMarked(stores) else { return false }
    return try await routedStoresHoldData(stores)
  }

  /// Clears a marker left by a restore stopped before any store committed. A restore in flight reads exactly like that until its stores commit, so this
  /// runs only where none can be: before a restore is offered, and after one has returned.
  public static func clearStaleMarker(_ stores: MemoirStores) async throws(StoreError) {
    guard try await isMarked(stores), try await !routedStoresHoldData(stores) else { return }
    try await stores.main.write { transaction in try MemoirProjectionSQL.run { try RestorePending.clear(in: transaction.database) } }
  }

  private static func isMarked(_ stores: MemoirStores) async throws(StoreError) -> Bool {
    try await stores.main.read { transaction in try MemoirProjectionSQL.run { try RestorePending.isMarked(in: transaction.database) } }
  }

  private static func routedStoresHoldData(_ stores: MemoirStores) async throws(StoreError) -> Bool {
    for kind in [MemoirStoreKind.restricted, .activity] {
      let kinds = dataKinds(of: kind)
      if try await stores.store(kind).read({ transaction in try transaction.holdsEntities(ofKinds: kinds) }) { return true }
    }
    return false
  }

  /// Everything that can be refused without writing: a missing store, a registry this build cannot read, an entity outside its store's kinds or not as
  /// its registry declares it, a key named twice, a command this build cannot read or whose ruleset it lacks, and a receipt image that no receipt record
  /// names or whose file differs from the record's size.
  public static func check(_ contents: MemoirRestoreContents) throws(MemoirRestoreError) {
    for kind in MemoirStoreKind.allCases {
      guard let store = contents.stores[kind] else { throw .storeMissing(kind) }
      guard store.registryVersion >= 1 else { throw .registryUnknown(kind, found: store.registryVersion) }
      guard store.registryVersion <= kind.registry.version else {
        throw .registryTooNew(kind, found: store.registryVersion, supported: kind.registry.version)
      }
      let kinds = dataKinds(of: kind)
      var refs = Set<EntityRef>()
      for entity in store.entities {
        let ref = entity.ref
        guard kinds.contains(ref.kind) else { throw .refused("kind \(ref.kind) does not belong in the \(kind.rawValue) store") }
        guard refs.insert(ref).inserted else { throw .refused("\(ref.kind)/\(ref.key) is listed twice") }
        if let refusal = kind.registry.importRefusal(of: entity) { throw .refused(refusal) }
        if case .appended(let ref, let item) = entity, ref.kind == MemoirKind.command.entityKind { try checkCommand(ref, item) }
      }
    }
    try checkReceipts(contents)
  }

  public static func restore(_ contents: MemoirRestoreContents, into stores: MemoirStores) async throws(MemoirRestoreError) {
    try await restore(contents, into: stores) { _ in }
  }

  static func restore(
    _ contents: MemoirRestoreContents, into stores: MemoirStores, beforeMainCommits: @escaping @Sendable (Database) throws -> Void
  ) async throws(MemoirRestoreError) {
    try check(contents)
    guard try await emptiness(of: stores) else { throw try await unfinished(stores) ? .unfinished : .vaultNotEmpty }
    let staged = try await stage(contents.receiptImages, in: stores.main)
    let reviews = contents.weeklyReviews
    let order: [MemoirStoreKind] = [.main, .restricted, .activity]
    let imports = order.map { kind in
      StoreImport(
        store: stores.store(kind), entities: contents.stores[kind]?.entities ?? [], kinds: dataKinds(of: kind),
        alongside: { database in
          guard kind == .main else { return }
          for blob in staged.blobs { try blob.record(in: database) }
          try WeeklyReviewAnswers.restore(reviews, in: database)
          try RestorePending.clear(in: database)
          try beforeMainCommits(database)
        })
    }
    do {
      let millis = Int64((stores.main.wallClock().timeIntervalSince1970 * 1000).rounded(.down))
      try await stores.main.write { transaction in try RestorePending.mark(atMillis: millis, in: transaction.database) }
      _ = try await VaultStore.importEntities(imports)
    } catch {
      staged.discard()
      if try await unfinished(stores) { throw .unfinished }
      try? await clearStaleMarker(stores)
      throw .store(error)
    }
  }

  private static func unfinished(_ stores: MemoirStores) async throws(MemoirRestoreError) -> Bool {
    do {
      return try await isUnfinished(stores)
    } catch {
      throw .store(error)
    }
  }

  private static func checkCommand(_ ref: EntityRef, _ item: [String: JSONValue]) throws(MemoirRestoreError) {
    guard let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key, let reader = MemberReader<MemoirCommand.Member>(object: .object(item)) else {
      throw .refused("command \(ref.key) is not a command")
    }
    let command: MemoirCommand
    do throws(MemoirUnreadable) {
      try reader.requireOnlyDeclaredMembers()
      command = try MemoirCommand(id: id, reading: reader)
    } catch {
      throw .refused("command \(ref.key) cannot be read: \(error.code)")
    }
    guard Ruleset.version(command.rulesetVersion) != nil else { throw .rulesetTooNew(command.rulesetVersion) }
    do throws(CommandRefusal) {
      _ = try MemoirCommandBody(command)
    } catch {
      throw .refused("command \(ref.key) is refused: \(error.code)")
    }
  }

  private static func emptiness(of stores: MemoirStores) async throws(MemoirRestoreError) -> Bool {
    do {
      return try await isEmpty(stores)
    } catch {
      throw .store(error)
    }
  }

  private static func checkReceipts(_ contents: MemoirRestoreContents) throws(MemoirRestoreError) {
    var receipts = [String: Int64]()
    for case .record(let ref, let fields) in contents.stores[.main]?.entities ?? [] where ref.kind == MemoirKind.receipt.entityKind {
      guard let blob = fields[ReceiptField.blob.rawValue]?.stringValue else { continue }
      receipts[blob] = fields[ReceiptField.byteCount.rawValue]?.intValue ?? -1
    }
    var named = Set<BlobID>()
    for image in contents.receiptImages {
      guard named.insert(image.blob).inserted else { throw .receipt("receipt image \(image.blob) is listed twice") }
      guard let byteCount = receipts[image.blob.description] else { throw .receipt("no receipt names image \(image.blob)") }
      let values = try? image.file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard let values, values.isRegularFile == true, values.isSymbolicLink != true else { throw .receipt("receipt image \(image.blob) is not a file") }
      guard values.fileSize.map(Int64.init) == byteCount else { throw .receipt("receipt image \(image.blob) is not the size its receipt records") }
    }
  }

  private struct StagedBlobs: Sendable {
    let blobs: [StagedBlob]
    let vault: VaultBlobs?

    func discard() {
      for blob in blobs { vault?.discard(blob) }
    }
  }

  private static func stage(_ images: [MemoirRestoreContents.ReceiptImage], in main: VaultStore) async throws(MemoirRestoreError) -> StagedBlobs {
    guard !images.isEmpty else { return StagedBlobs(blobs: [], vault: nil) }
    let vault: VaultBlobs
    do {
      vault = try VaultBlobs(store: main)
    } catch {
      throw .blob(error)
    }
    var staged = [StagedBlob]()
    for image in images {
      do {
        staged.append(try await vault.stage(contentsOf: image.file, as: image.blob))
      } catch {
        StagedBlobs(blobs: staged, vault: vault).discard()
        throw .blob(error)
      }
    }
    return StagedBlobs(blobs: staged, vault: vault)
  }
}
