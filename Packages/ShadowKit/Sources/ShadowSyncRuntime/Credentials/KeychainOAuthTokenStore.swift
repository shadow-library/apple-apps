import Foundation
import ShadowKeychain
import ShadowNetworking

/// Takes the device store: each device signs in for itself, so refresh tokens never leave it.
public struct KeychainOAuthTokenStore: OAuthTokenStore, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let item: String
  private let store: any SecureStore

  public init(store: any SecureStore, item: String) {
    self.store = store
    self.item = item
  }

  public init(store: any SecureStore, kind: SyncProviderKind, clientID: String) {
    self.init(store: store, item: Self.itemName(kind: kind, clientID: clientID))
  }

  public static func itemName(kind: SyncProviderKind, clientID: String) -> String {
    "oauth/\(kind.rawValue)/\(clientID)"
  }

  public func load() async throws(OAuthError) -> OAuthTokens? {
    let data: Data?
    do {
      data = try store.data(forKey: item)
    } catch {
      throw .tokenStorage(error.reason)
    }
    guard let data else { return nil }
    guard let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else { throw .tokenStorage("the stored tokens are unreadable") }
    return tokens
  }

  public func save(_ tokens: OAuthTokens) async throws(OAuthError) {
    guard let data = try? JSONEncoder().encode(tokens) else { throw .tokenStorage("the tokens could not be encoded") }
    do {
      try store.setData(data, forKey: item)
    } catch {
      throw .tokenStorage(error.reason)
    }
  }

  public func clear() async throws(OAuthError) {
    do {
      try store.removeValue(forKey: item)
    } catch {
      throw .tokenStorage(error.reason)
    }
  }

  public var description: String { "KeychainOAuthTokenStore(item: \(item))" }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, children: ["item": item], displayStyle: .struct) }
}
