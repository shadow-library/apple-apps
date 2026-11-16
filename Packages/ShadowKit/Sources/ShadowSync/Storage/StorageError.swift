import Foundation
import ShadowCore

public enum StorageError: ShadowError, Equatable {
  case notFound(ObjectKey)
  case alreadyExists(ObjectKey)
  /// This provider cannot store the key beside an existing object.
  case keyConflict(ObjectKey)
  case tooLarge(ObjectKey, limit: Int)
  case quotaExceeded
  case rateLimited(retryAfter: Duration?)
  case unauthenticated
  case unavailable(String)
  case underlying(String)

  public var code: String {
    switch self {
    case .notFound: "storage.not_found"
    case .alreadyExists: "storage.already_exists"
    case .keyConflict: "storage.key_conflict"
    case .tooLarge: "storage.too_large"
    case .quotaExceeded: "storage.quota_exceeded"
    case .rateLimited: "storage.rate_limited"
    case .unauthenticated: "storage.unauthenticated"
    case .unavailable: "storage.unavailable"
    case .underlying: "storage.underlying"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notFound(let key): "No object at \(key)"
    case .alreadyExists(let key): "An object already exists at \(key)"
    case .keyConflict(let key): "Cannot store \(key) beside an existing object"
    case .tooLarge(let key, let limit): "Object \(key) exceeds the \(limit) byte limit"
    case .quotaExceeded: "Storage quota exceeded"
    case .rateLimited(let retryAfter): retryAfter.map { "Rate limited, retry after \($0)" } ?? "Rate limited"
    case .unauthenticated: "Storage is not authenticated"
    case .unavailable(let message): "Storage unavailable: \(message)"
    case .underlying(let message): "Storage failure: \(message)"
    }
  }
}
