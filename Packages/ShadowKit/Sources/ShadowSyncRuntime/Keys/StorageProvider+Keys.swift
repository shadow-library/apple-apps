import Foundation
import ShadowSync

extension StorageProvider {
  func getIfPresent(_ key: ObjectKey) async throws(StorageError) -> Data? {
    do {
      return try await get(key)
    } catch {
      guard case .notFound = error else { throw error }
      return nil
    }
  }

  /// The listing may lag behind recent puts, so it is never taken as the full set.
  func listedCopies(of recipientID: String) async throws(StorageError) -> Set<KeyID> {
    var keys: Set<KeyID> = []
    for object in try await listAll(prefix: "keys/\(recipientID)/") {
      guard case .sealedKey(let recipient, let key) = VaultPath.classify(object.key), recipient == recipientID else { continue }
      keys.insert(key)
    }
    return keys
  }
}
