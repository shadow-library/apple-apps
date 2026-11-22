import Foundation
import Security
import ShadowKeychain
import ShadowNetworking

/// The demo's keys: none are read and none can be saved, so the demo never touches the owner's keychain.
nonisolated struct DemoKeyStore: SecureStore {
  func data(forKey key: String) throws(SecureStoreError) -> Data? { nil }

  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) { throw .unexpectedStatus(errSecReadOnly) }

  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool { throw .unexpectedStatus(errSecReadOnly) }

  func removeValue(forKey key: String) throws(SecureStoreError) {}

  func allKeys() throws(SecureStoreError) -> [String] { [] }
}

/// The demo's only transport, which refuses every request as offline.
nonisolated struct OfflineTransport: HTTPTransport, HTTPStreamingTransport {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }

  func stream(_ request: URLRequest) async throws -> HTTPStreamingResponse { throw URLError(.notConnectedToInternet) }
}
