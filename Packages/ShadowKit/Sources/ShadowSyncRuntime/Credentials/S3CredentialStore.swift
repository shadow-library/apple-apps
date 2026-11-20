import CryptoKit
import Foundation
import ShadowKeychain
import ShadowSyncS3

/// Takes the synced store: the credentials follow the user's other devices through iCloud Keychain.
public struct S3CredentialStore: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  static let domain = "com.shadow.library.shadowsyncruntime.s3-credentials"

  private struct Stored: Codable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?
  }

  private let store: any SecureStore

  public init(store: any SecureStore) {
    self.store = store
  }

  public static func itemName(for settings: SyncS3Settings) -> String {
    var hasher = SHA256()
    for part in [domain, settings.endpoint.absoluteString, settings.bucket, settings.keyPrefix] {
      hasher.update(data: Data(part.utf8))
      hasher.update(data: Data([0]))
    }
    return "s3-credentials/" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public func load(for settings: SyncS3Settings) throws(SyncCredentialError) -> S3Credentials? {
    let data: Data?
    do {
      data = try store.data(forKey: Self.itemName(for: settings))
    } catch {
      throw Self.failure(error)
    }
    guard let data else { return nil }
    guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { throw .unreadable }
    do {
      return try S3Credentials(accessKeyID: stored.accessKeyID, secretAccessKey: stored.secretAccessKey, sessionToken: stored.sessionToken)
    } catch {
      throw .unreadable
    }
  }

  public func save(_ credentials: S3Credentials, for settings: SyncS3Settings) throws(SyncCredentialError) {
    let stored = Stored(accessKeyID: credentials.accessKeyID, secretAccessKey: credentials.secretAccessKey, sessionToken: credentials.sessionToken)
    guard let data = try? JSONEncoder().encode(stored) else { throw .keychain("the credentials could not be encoded") }
    do {
      try store.setData(data, forKey: Self.itemName(for: settings))
    } catch {
      throw Self.failure(error)
    }
  }

  public func remove(for settings: SyncS3Settings) throws(SyncCredentialError) {
    do {
      try store.removeValue(forKey: Self.itemName(for: settings))
    } catch {
      throw Self.failure(error)
    }
  }

  public var description: String { "S3CredentialStore" }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

  private static func failure(_ error: SecureStoreError) -> SyncCredentialError {
    error.isInteractionNotAllowed ? .deviceLocked : .keychain(error.reason)
  }
}
