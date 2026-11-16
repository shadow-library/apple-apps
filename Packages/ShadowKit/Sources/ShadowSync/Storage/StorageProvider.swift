import Foundation

public protocol StorageProvider: Sendable {
  var capabilities: StorageCapabilities { get }

  /// Returns objects whose key starts with `prefix` (a plain string prefix; empty lists everything) in ascending key order, comparing bytes.
  /// Order is ascending within and across pages and a full drain returns each object at most once.
  /// The listing may be stale and omit recent objects but never invents one. `cursor` is the `next` of the previous page, nil for the first.
  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage

  /// Throws `notFound` for a missing key.
  func get(_ key: ObjectKey) async throws(StorageError) -> Data

  /// All-or-nothing as readers see it. `.overwrite` replaces.
  /// `.ifAbsent` throws `alreadyExists` when the key exists, atomically if `capabilities.supportsPutIfAbsent` and as a best-effort check otherwise.
  /// Data larger than `capabilities.maxObjectBytes` throws `tooLarge`.
  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt

  /// Missing keys are ignored. Takes effect eventually.
  func delete(_ keys: [ObjectKey]) async throws(StorageError)

  /// Yields when the provider learns of remote changes. May never yield.
  func changeNotices() -> AsyncStream<Void>
}

extension StorageProvider {
  public func listAll(prefix: String) async throws(StorageError) -> [StorageObject] {
    var objects: [StorageObject] = []
    var cursor: ListCursor?
    repeat {
      let page = try await list(prefix: prefix, after: cursor)
      guard page.next == nil || page.next != cursor else { throw .underlying("list cursor did not advance") }
      objects.append(contentsOf: page.objects)
      cursor = page.next
    } while cursor != nil
    return objects
  }
}
