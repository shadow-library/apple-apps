import Foundation
import ShadowKeychain

/// `ring` and `credentials` must be synced stores; `marker` and `tokens` must be this-device stores.
public struct SyncSecureStores: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let ring: any SecureStore
  public let credentials: any SecureStore
  public let marker: any SecureStore
  public let tokens: any SecureStore

  public init(ring: any SecureStore, credentials: any SecureStore, marker: any SecureStore, tokens: any SecureStore) {
    self.ring = ring
    self.credentials = credentials
    self.marker = marker
    self.tokens = tokens
  }

  /// `app` is the app's bundle id; `sharedAccessGroup` is the expanded shared group (team prefix included), or nil for the app's default group.
  /// A nil group on a device store means the app's first keychain access group, which `Project.app` lists as the app's own.
  public static func keychain(app: String, sharedAccessGroup: String?) -> SyncSecureStores {
    SyncSecureStores(
      ring: KeychainStore(service: "\(app).sync", accessGroup: sharedAccessGroup, scope: .synced(.afterFirstUnlock)),
      credentials: KeychainStore(service: "\(app).sync.credentials", accessGroup: sharedAccessGroup, scope: .synced(.afterFirstUnlock)),
      marker: KeychainStore(service: "\(app).sync.device", scope: .device(.afterFirstUnlockThisDeviceOnly)),
      tokens: KeychainStore(service: "\(app).sync.tokens", scope: .device(.afterFirstUnlockThisDeviceOnly))
    )
  }

  public var s3Credentials: S3CredentialStore { S3CredentialStore(store: credentials) }

  public func oauthTokens(kind: SyncProviderKind, clientID: String) -> KeychainOAuthTokenStore {
    KeychainOAuthTokenStore(store: tokens, kind: kind, clientID: clientID)
  }

  public var description: String { "SyncSecureStores" }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
