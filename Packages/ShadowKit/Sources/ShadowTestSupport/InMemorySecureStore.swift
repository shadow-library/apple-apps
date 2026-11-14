import Foundation
import ShadowKeychain
import Synchronization

public final class InMemorySecureStore: SecureStore {
  private let storage: Mutex<[String: Data]>

  public init(_ initial: [String: Data] = [:]) {
    storage = Mutex(initial)
  }

  public func data(forKey key: String) throws(SecureStoreError) -> Data? {
    storage.withLock { $0[key] }
  }

  public func setData(_ data: Data, forKey key: String) throws(SecureStoreError) {
    storage.withLock { $0[key] = data }
  }

  public func removeValue(forKey key: String) throws(SecureStoreError) {
    _ = storage.withLock { $0.removeValue(forKey: key) }
  }
}
