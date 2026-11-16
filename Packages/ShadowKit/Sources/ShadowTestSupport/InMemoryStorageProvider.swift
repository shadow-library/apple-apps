import Foundation
import ShadowSync
import Synchronization

public final class InMemoryStorageProvider: StorageProvider {
  public struct CallCounts: Sendable, Equatable {
    public internal(set) var list = 0
    public internal(set) var get = 0
    public internal(set) var put = 0
    public internal(set) var delete = 0
  }

  private struct State {
    var objects: [ObjectKey: Data] = [:]
    var counts = CallCounts()
  }

  public let capabilities: StorageCapabilities

  private let state = Mutex(State())
  private let pageSize: Int
  private let serverClock: (@Sendable () -> Date)?

  public init(maxObjectBytes: Int = .max, classPolicy: StorageClassPolicy = .unrestricted, pageSize: Int = 1000, serverClock: (@Sendable () -> Date)? = nil) {
    precondition(pageSize > 0, "page size must be positive")
    self.pageSize = pageSize
    self.serverClock = serverClock
    capabilities = StorageCapabilities(
      pushesChangeNotices: false,
      supportsPutIfAbsent: true,
      hasChangeFeed: false,
      reportsServerTime: serverClock != nil,
      maxObjectBytes: maxObjectBytes,
      classPolicy: classPolicy
    )
  }

  public var callCounts: CallCounts { state.withLock { $0.counts } }

  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    let matching = state.withLock { state in
      state.counts.list += 1
      return state.objects.filter { $0.key.hasPrefix(prefix) }.map { StorageObject(key: $0.key, size: $0.value.count) }.sorted { $0.key < $1.key }
    }
    let remaining = cursor.map { cursor in matching.filter { cursor.token.utf8.lexicographicallyPrecedes($0.key.rawValue.utf8) } } ?? matching
    let objects = Array(remaining.prefix(pageSize))
    let next = remaining.count > pageSize ? objects.last.map { ListCursor(token: $0.key.rawValue) } : nil
    return ListPage(objects: objects, next: next)
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    let data = state.withLock { state in
      state.counts.get += 1
      return state.objects[key]
    }
    guard let data else { throw .notFound(key) }
    return data
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    let limit = capabilities.maxObjectBytes
    let time = serverClock?()
    return try state.withLock { (state) throws(StorageError) -> PutReceipt in
      state.counts.put += 1
      guard data.count <= limit else { throw .tooLarge(key, limit: limit) }
      guard condition == .overwrite || state.objects[key] == nil else { throw .alreadyExists(key) }
      state.objects[key] = data
      return PutReceipt(serverTime: time)
    }
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    state.withLock { state in
      state.counts.delete += 1
      for key in keys { state.objects[key] = nil }
    }
  }

  public func changeNotices() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }
}
