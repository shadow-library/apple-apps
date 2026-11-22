import Foundation
import ShadowCore
import ShadowSync
import ShadowSyncRuntime

/// A failure of a key screen, whichever layer raised it.
enum SyncKeysError: Error, Equatable {
  case services(SyncStartupError)
  case recovery(RecoveryError)
  case exchange(KeyExchangeError)
  case phrase(RecoveryPhraseError)
  /// The vault was replaced by another while a flow ran, so the flow was stopped.
  case vaultChanged

  /// The key services the call went through belong to an attachment the runtime no longer holds.
  var isStaleAccess: Bool {
    switch self {
    case .recovery(.unavailable), .exchange(.unavailable): true
    default: false
    }
  }

  static func recovery<T>(_ body: () async throws(RecoveryError) -> T) async throws(SyncKeysError) -> T {
    do {
      return try await body()
    } catch {
      throw .recovery(error)
    }
  }

  static func exchange<T>(_ body: () async throws(KeyExchangeError) -> T) async throws(SyncKeysError) -> T {
    do {
      return try await body()
    } catch {
      throw .exchange(error)
    }
  }

  var code: String {
    switch self {
    case .services(let error): error.code
    case .recovery(let error): error.code
    case .exchange(let error): error.code
    case .phrase(let error): error.code
    case .vaultChanged: "sync-keys.vault-changed"
    }
  }
}
