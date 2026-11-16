import Foundation
import ShadowSync

/// Puts a server date from `serverClock` on every put receipt, the way an HTTPS provider's responses carry one, over a provider that has none.
public final class ServerTimeStorageProvider: StorageProvider {
  private let inner: any StorageProvider
  private let serverClock: @Sendable () -> Date

  public init(wrapping inner: any StorageProvider, serverClock: @escaping @Sendable () -> Date) {
    self.inner = inner
    self.serverClock = serverClock
  }

  public var capabilities: StorageCapabilities {
    let base = inner.capabilities
    return StorageCapabilities(
      pushesChangeNotices: base.pushesChangeNotices, supportsPutIfAbsent: base.supportsPutIfAbsent, hasChangeFeed: base.hasChangeFeed, reportsServerTime: true,
      maxObjectBytes: base.maxObjectBytes, classPolicy: base.classPolicy)
  }

  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    _ = try await inner.put(key, data: data, condition: condition)
    return PutReceipt(serverTime: serverClock())
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  public func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}
