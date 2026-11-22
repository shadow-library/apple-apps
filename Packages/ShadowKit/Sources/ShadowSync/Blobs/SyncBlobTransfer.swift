import CryptoKit
import Foundation
import GRDB
import OSLog
import ShadowCore
import ShadowStore

struct SyncBlobContext: Sendable {
  static let logger = Logger(category: "blobs")

  let store: VaultStore
  let provider: any StorageProvider
  let vault: VaultID
  let ring: KeyRing
  let configuration: SyncConfiguration
  let trustedClock: TrustedClock
  let files: BlobFiles
  let now: @Sendable () -> Date

  var millis: Int64 { BlobFiles.millis(now()) }

  var syncClass: SyncClass { .ofBlobs(in: store.registry) }

  func rows(_ states: Set<SyncBlobState>) async throws(SyncError) -> [SyncBlobRow] {
    try await read { try SyncBlobTable.rows(in: states, in: $0) }
  }

  func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws(SyncError) -> T {
    do {
      return try await store.read { try body($0.database) }
    } catch {
      throw SyncError(converting: error)
    }
  }

  func write<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws(SyncError) -> T {
    do {
      return try await store.write { try body($0.database) }
    } catch {
      throw SyncError(converting: error)
    }
  }

  func blobRead<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws(BlobError) -> T {
    do {
      return try await store.read { try body($0.database) }
    } catch {
      throw .store(error)
    }
  }

  func blobWrite<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws(BlobError) -> T {
    do {
      return try await store.write { try body($0.database) }
    } catch {
      throw .store(error)
    }
  }
}

/// Puts every waiting blob before the segments of the same upload, so a reader that applies a reference usually finds its blob already stored.
struct SyncBlobUploader {
  let context: SyncBlobContext

  func run(sealedWith key: VaultKey) async throws(SyncError) {
    try await restoreReferenced()
    let pending = try await context.rows([.pending])
    guard !pending.isEmpty else { return }
    let policy = context.provider.capabilities.classPolicy
    if let refused = pending.first(where: { !policy.admits($0.syncClass, under: context.configuration) }) { throw .blob(.classRefused(refused.syncClass)) }
    for row in pending {
      do {
        try await upload(row, sealedWith: key)
      } catch {
        guard case .blob(.file(let reason)) = error else { throw error }
        SyncBlobContext.logger.error("Blob left waiting: its local file is unreadable blob=\(row.id.description, privacy: .public) reason=\(reason, privacy: .private)")
      }
    }
  }

  /// An unsent change naming a blob this device holds but did not put, or put and since deleted, puts it again when storage lists no complete copy.
  private func restoreReferenced() async throws(SyncError) {
    let held = try await context.rows([.cached, .deleting, .deleted]).filter { context.files.exists($0.id) }
    guard !held.isEmpty else { return }
    let lines: [LoggedChange]
    do {
      lines = try await context.store.pendingChanges(limit: Int.max)
    } catch {
      throw SyncError(converting: error)
    }
    let matcher = BlobIDMatcher(held.map(\.id))
    var named = Set<BlobID>()
    for change in lines where matcher.scan(change.line, into: &named) {}
    var restored: [SyncBlobRow] = []
    for row in held where named.contains(row.id) {
      let listing: [StorageObject]
      do {
        listing = try await context.provider.listAll(prefix: row.id.prefix)
      } catch {
        throw .storage(error)
      }
      if SyncBlobFetcher.completeSets(listing, of: row.id).isEmpty { restored.append(row) }
    }
    guard !restored.isEmpty else { return }
    let restoring = restored
    try await context.write { db in
      for var row in restoring {
        row.state = .pending
        row.hold()
        row.deleted = nil
        try SyncBlobTable.save(row, in: db)
      }
    }
  }

  private func upload(_ row: SyncBlobRow, sealedWith key: VaultKey) async throws(SyncError) {
    let id = row.id
    guard context.files.exists(id) else {
      SyncBlobContext.logger.error("Blob waiting to upload has no local file blob=\(id.description, privacy: .public)")
      try await context.write { try SyncBlobTable.remove(id, in: $0) }
      return
    }
    let limit = context.provider.capabilities.maxObjectBytes
    guard let layout = BlobCodec.layout(size: row.size, partBytes: context.configuration.blobPartBytes, limit: limit, vault: context.vault) else {
      throw .blob(.tooLarge(size: row.size, limit: limit))
    }
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: context.files.url(of: id))
    } catch {
      throw .blob(.file(error.localizedDescription))
    }
    defer { try? handle.close() }
    let condition: PutCondition = context.provider.capabilities.supportsPutIfAbsent ? .ifAbsent : .overwrite
    for (index, range) in layout.enumerated() {
      let header = BlobPartHeader(
        blob: id, syncClass: row.syncClass, digest: row.digest, size: row.size, part: index + 1, parts: layout.count, offset: range.lowerBound, length: range.count)
      let data: Data
      do {
        data = try BlobCodec.seal(header, from: handle, vault: context.vault, key: key)
      } catch {
        throw .blob(error)
      }
      do {
        let receipt = try await context.provider.put(VaultPath.blobPart(name: id.description, part: index + 1, parts: layout.count), data: data, condition: condition)
        if let serverTime = receipt.serverTime { context.trustedClock.record(serverDate: serverTime) }
      } catch {
        guard case .alreadyExists = error else { throw .storage(error) }
      }
    }
    let millis = context.millis
    let parts = layout.count
    try await context.write { db in
      guard var current = try SyncBlobTable.load(id, in: db), current.state == .pending else { return }
      current.state = .uploaded
      current.parts = parts
      current.uploaded = millis
      try SyncBlobTable.save(current, in: db)
    }
  }
}

struct SyncBlobFetcher {
  let context: SyncBlobContext

  func fetch(_ id: BlobID) async throws(BlobError) -> URL {
    if let held = try await heldURL(of: id) { return held }
    let policy = context.provider.capabilities.classPolicy
    guard policy.admits(context.syncClass, under: context.configuration) else { throw .classRefused(context.syncClass) }
    _ = try? context.ring.refresh()
    let listing: [StorageObject]
    do {
      listing = try await context.provider.listAll(prefix: id.prefix)
    } catch {
      throw .storage(error)
    }
    var failure = BlobError.missing(id)
    for parts in Self.completeSets(listing, of: id) {
      do {
        return try await download(id, parts: parts)
      } catch {
        if case .storage = error { throw error }
        failure = error
      }
    }
    throw failure
  }

  /// Part counts for which every part is listed, largest first; one blob put through two providers' limits can be split two ways.
  static func completeSets(_ listing: [StorageObject], of id: BlobID) -> [Int] {
    var seen: [Int: Set<Int>] = [:]
    for object in listing {
      guard case .blobPart(let name, let part, let parts) = VaultPath.classify(object.key), name == id.description else { continue }
      seen[parts, default: []].insert(part)
    }
    return seen.filter { $0.value.count == $0.key }.keys.sorted(by: >)
  }

  private func heldURL(of id: BlobID) async throws(BlobError) -> URL? {
    let row = try await context.blobRead { try SyncBlobTable.load(id, in: $0) }
    guard row != nil, context.files.exists(id) else { return nil }
    return context.files.url(of: id)
  }

  private func download(_ id: BlobID, parts: Int) async throws(BlobError) -> URL {
    let temporary = try context.files.temporary(for: id)
    defer { context.files.discard(temporary) }
    let handle: FileHandle
    do {
      handle = try FileHandle(forWritingTo: temporary)
    } catch {
      throw .file(error.localizedDescription)
    }
    defer { try? handle.close() }
    var first: BlobPartHeader?
    var written = 0
    var hasher = SHA256()
    let limit = context.configuration.maximumBlobBytes
    let (vault, ring) = (context.vault, context.ring)
    for part in 1...parts {
      let key = VaultPath.blobPart(name: id.description, part: part, parts: parts)
      let sealed: Data
      do {
        sealed = try await context.provider.get(key)
      } catch {
        guard case .notFound = error else { throw .storage(error) }
        throw .missing(id)
      }
      let append = { (bytes: Data) throws(BlobError) in
        guard written + bytes.count <= limit else { throw .tooLarge(size: written + bytes.count, limit: limit) }
        do {
          try handle.write(contentsOf: bytes)
        } catch {
          throw .file(error.localizedDescription)
        }
        hasher.update(data: bytes)
        written += bytes.count
      }
      let header = try BlobCodec.open(sealed, at: key, vault: vault, keys: { ring.key($0) }, sink: append)
      if let first, !header.belongs(with: first) { throw .corrupt(id, reason: "the parts belong to different copies") }
      guard header.offset + header.length == written else { throw .corrupt(id, reason: "part \(part) does not continue the previous one") }
      first = first ?? header
    }
    guard let first, written == first.size, lowercaseHex(hasher.finalize()) == first.digest else { throw .corrupt(id, reason: "the content does not match its digest") }
    do {
      try handle.synchronize()
    } catch {
      throw .file(error.localizedDescription)
    }
    try context.files.commit(temporary, as: id)
    let row = SyncBlobRow(
      id: id, state: .cached, syncClass: first.syncClass, size: first.size, digest: first.digest, parts: nil, added: context.millis, uploaded: nil, released: nil,
      releasePoints: nil, releaseRetired: [], deleted: nil)
    try await context.blobWrite { try SyncBlobTable.insert(row, in: $0) }
    return context.files.url(of: id)
  }
}
