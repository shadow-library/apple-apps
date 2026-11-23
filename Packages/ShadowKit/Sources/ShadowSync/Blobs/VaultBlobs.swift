import CryptoKit
import Foundation
import GRDB
import ShadowCore
import ShadowStore

public enum BlobStatus: Sendable, Equatable {
  case waitingToUpload
  case stored
  case downloaded
  /// Removed from storage because nothing referred to it; the local copy is kept for a while.
  case removed
}

/// A store's binary attachments on this device: put here, uploaded by the sync engine beside the change log, fetched by the engine on demand. A record
/// refers to one by writing its `BlobID`'s description into a field.
public struct VaultBlobs: Sendable {
  public let store: VaultStore
  public let maximumBytes: Int
  let directory: URL
  let syncClass: SyncClass

  public init(store: VaultStore, maximumBytes: Int = SyncConfiguration.defaultMaximumBlobBytes) throws(BlobError) {
    guard let directory = store.blobDirectory else { throw .noDirectory }
    self.store = store
    self.maximumBytes = maximumBytes
    self.directory = directory
    syncClass = .ofBlobs(in: store.registry)
  }

  public func put(_ data: Data) async throws(BlobError) -> BlobID {
    guard data.count <= maximumBytes else { throw .tooLarge(size: data.count, limit: maximumBytes) }
    let id = BlobID.random()
    let files = BlobFiles(directory: directory)
    try files.place(id) { (temporary: URL) throws(BlobError) in
      do {
        try data.write(to: temporary, options: .completeFileProtectionUntilFirstUserAuthentication)
      } catch {
        throw .file(error.localizedDescription)
      }
    }
    try await record(id, size: data.count, digest: BlobCodec.digest(of: data))
    return id
  }

  /// Copies the file and hashes it a chunk at a time, so a large attachment is never read into memory whole.
  public func put(contentsOf source: URL) async throws(BlobError) -> BlobID {
    let size = try BlobFiles.size(of: source)
    guard size <= maximumBytes else { throw .tooLarge(size: size, limit: maximumBytes) }
    let id = BlobID.random()
    let digest = try place(copyOf: source, size: size, as: id)
    try await record(id, size: size, digest: digest)
    return id
  }

  /// Restoring an export: the file goes in under the id the export recorded, which this store must not hold yet. Until the import that writes the record
  /// naming it calls `StagedBlob.record(in:)` in its own transaction nothing knows the file, and `discard(_:)` removes it if that import fails. A file
  /// with no row is what a restore stopped before its import committed leaves, so it is replaced.
  public func stage(contentsOf source: URL, as id: BlobID) async throws(BlobError) -> StagedBlob {
    let size = try BlobFiles.size(of: source)
    guard size <= maximumBytes else { throw .tooLarge(size: size, limit: maximumBytes) }
    guard try await row(of: id) == nil else { throw .alreadyHeld(id) }
    let files = BlobFiles(directory: directory)
    if files.exists(id) {
      files.remove(id)
      guard !files.exists(id) else { throw .file("a file an unfinished restore left cannot be removed") }
    }
    let digest = try place(copyOf: source, size: size, as: id)
    return StagedBlob(id: id, size: size, digest: digest, syncClass: syncClass, added: BlobFiles.millis(store.wallClock()))
  }

  public func discard(_ staged: StagedBlob) {
    BlobFiles(directory: directory).remove(staged.id)
  }

  /// The local file, when this device holds the blob; otherwise fetch it through the sync runtime.
  public func localURL(of id: BlobID) async throws(BlobError) -> URL? {
    guard try await row(of: id) != nil else { return nil }
    let url = BlobFiles(directory: directory).url(of: id)
    return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
  }

  public func status(of id: BlobID) async throws(BlobError) -> BlobStatus? {
    guard let row = try await row(of: id) else { return nil }
    switch row.state {
    case .pending: return .waitingToUpload
    case .uploaded: return .stored
    case .cached: return .downloaded
    case .deleting, .deleted: return .removed
    }
  }

  public static func hasPendingUploads(in store: VaultStore) async throws(BlobError) -> Bool {
    do {
      return try await store.read { try !SyncBlobTable.rows(in: [.pending], in: $0.database).isEmpty }
    } catch {
      throw .store(error)
    }
  }

  private func place(copyOf source: URL, size: Int, as id: BlobID) throws(BlobError) -> String {
    var digest = ""
    try BlobFiles(directory: directory).place(id) { (temporary: URL) throws(BlobError) in
      do {
        try FileManager.default.copyItem(at: source, to: temporary)
      } catch {
        throw .file(error.localizedDescription)
      }
      try BlobFiles.protect(temporary)
      guard try BlobFiles.size(of: temporary) == size else { throw .file("the source changed while it was copied") }
      digest = try BlobFiles.digest(of: temporary)
    }
    return digest
  }

  private func row(of id: BlobID) async throws(BlobError) -> SyncBlobRow? {
    do {
      return try await store.read { try SyncBlobTable.load(id, in: $0.database) }
    } catch {
      throw .store(error)
    }
  }

  private func record(_ id: BlobID, size: Int, digest: String) async throws(BlobError) {
    let millis = BlobFiles.millis(store.wallClock())
    let row = SyncBlobRow(
      id: id, state: .pending, syncClass: syncClass, size: size, digest: digest, parts: nil, added: millis, uploaded: nil, released: nil, releasePoints: nil,
      releaseRetired: [], deleted: nil)
    do {
      try await store.write { try SyncBlobTable.insert(row, in: $0.database) }
    } catch {
      BlobFiles(directory: directory).remove(id)
      throw .store(error)
    }
  }
}

/// A restored blob's file in place, waiting for the import that names it; see ``VaultBlobs/stage(contentsOf:as:)``.
public struct StagedBlob: Sendable, Equatable {
  public let id: BlobID
  let size: Int
  let digest: String
  let syncClass: SyncClass
  let added: Int64

  /// Records the blob for upload in the caller's transaction, refusing an id the store came to hold meanwhile.
  public func record(in database: Database) throws {
    guard try SyncBlobTable.load(id, in: database) == nil else { throw BlobError.alreadyHeld(id) }
    try SyncBlobTable.insert(
      SyncBlobRow(
        id: id, state: .pending, syncClass: syncClass, size: size, digest: digest, parts: nil, added: added, uploaded: nil, released: nil, releasePoints: nil,
        releaseRetired: [], deleted: nil),
      in: database)
  }
}

struct BlobFiles: Sendable {
  let directory: URL

  func url(of id: BlobID) -> URL {
    directory.appending(path: id.description, directoryHint: .notDirectory)
  }

  func exists(_ id: BlobID) -> Bool {
    FileManager.default.fileExists(atPath: url(of: id).path(percentEncoded: false))
  }

  /// Writes through a temporary name in the same folder and moves it into place, so a blob's file is either whole or absent.
  func place(_ id: BlobID, _ write: (URL) throws(BlobError) -> Void) throws(BlobError) {
    let temporary = try temporaryURL(for: id)
    defer { discard(temporary) }
    try write(temporary)
    try commit(temporary, as: id)
  }

  /// An empty file under a name no listing of blobs reads.
  func temporary(for id: BlobID) throws(BlobError) -> URL {
    let url = try temporaryURL(for: id)
    guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else { throw .file("cannot create \(url.lastPathComponent)") }
    try Self.protect(url)
    return url
  }

  /// A copy keeps its source's protection class, which may leave it unreadable while the device is locked; a blob must be readable then, as the database is.
  static func protect(_ url: URL) throws(BlobError) {
    #if !os(macOS)
      do {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path(percentEncoded: false))
      } catch {
        throw .file(error.localizedDescription)
      }
    #endif
  }

  func commit(_ temporary: URL, as id: BlobID) throws(BlobError) {
    let target = url(of: id)
    guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return }
    do {
      try FileManager.default.moveItem(at: temporary, to: target)
    } catch {
      throw .file(error.localizedDescription)
    }
  }

  func discard(_ temporary: URL) {
    try? FileManager.default.removeItem(at: temporary)
  }

  private func temporaryURL(for id: BlobID) throws(BlobError) -> URL {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw .file(error.localizedDescription)
    }
    return directory.appending(path: ".\(id.description).\(UUID().uuidString.lowercased()).partial", directoryHint: .notDirectory)
  }

  func remove(_ id: BlobID) {
    try? FileManager.default.removeItem(at: url(of: id))
  }

  static func size(of url: URL) throws(BlobError) -> Int {
    do {
      guard let size = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber else { throw BlobError.file("no file size") }
      return size.intValue
    } catch let error as BlobError {
      throw error
    } catch {
      throw .file(error.localizedDescription)
    }
  }

  static func digest(of url: URL) throws(BlobError) -> String {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hasher = SHA256()
      while let chunk = try handle.read(upToCount: BlobCodec.readChunk), !chunk.isEmpty { hasher.update(data: chunk) }
      return lowercaseHex(hasher.finalize())
    } catch {
      throw .file(error.localizedDescription)
    }
  }

  static func millis(_ date: Date) -> Int64 {
    max(0, Int64((date.timeIntervalSince1970 * 1_000).rounded(.down)))
  }
}
