import Foundation
import ShadowCore
import ShadowStore

public enum BlobError: ShadowError {
  case tooLarge(size: Int, limit: Int)
  /// No complete copy is stored yet, or it was removed after nothing referred to it.
  case missing(BlobID)
  case corrupt(BlobID, reason: String)
  /// The copy is sealed with a ring key this device does not hold.
  case keyUnavailable(BlobID, KeyID)
  /// The provider may not hold blobs of the store's sync class.
  case classRefused(SyncClass)
  /// An in-memory store keeps no blobs.
  case noDirectory
  /// No storage is attached and the blob is not held on this device.
  case notAttached
  case storage(StorageError)
  case store(StoreError)
  case file(String)

  public var code: String {
    switch self {
    case .tooLarge: "blob.too-large"
    case .missing: "blob.missing"
    case .corrupt: "blob.corrupt"
    case .keyUnavailable: "blob.key-unavailable"
    case .classRefused: "blob.class-refused"
    case .noDirectory: "blob.no-directory"
    case .notAttached: "blob.not-attached"
    case .storage(let error): error.code
    case .store(let error): error.code
    case .file: "blob.file"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .tooLarge(let size, let limit): "A blob of \(size) bytes exceeds the limit of \(limit) bytes."
    case .missing(let id): "Blob \(id) is not stored."
    case .corrupt(let id, let reason): "Blob \(id) is unreadable: \(reason)."
    case .keyUnavailable(let id, let key): "Blob \(id) is sealed with key \(key), which this device does not hold."
    case .classRefused(let syncClass): "This provider may not hold \(syncClass.rawValue)-class blobs."
    case .noDirectory: "An in-memory store keeps no blobs."
    case .notAttached: "No storage is attached and the blob is not on this device."
    case .storage(let error): error.errorDescription
    case .store(let error): error.errorDescription
    case .file(let reason): "A blob file could not be written or read: \(reason)."
    }
  }
}
