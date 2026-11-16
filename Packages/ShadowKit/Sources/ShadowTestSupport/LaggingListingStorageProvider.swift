import Foundation
import ShadowSync
import Synchronization

/// Leaves objects that exist, and may have been listed before, out of later listings for a while, as an eventually consistent listing does; reads still find them.
/// A key is hidden on purpose with `hide(_:listings:)`, or at random: each listing hides each eligible object it would show with `probability`, for a number of listings
/// drawn from `listings`, this one included.
public final class LaggingListingStorageProvider: StorageProvider {
  private struct State {
    var generator: SeededGenerator
    var enabled = true
    var remaining: [ObjectKey: Int] = [:]
    var omitted: [String: Set<ObjectKey>] = [:]
    var hidings = 0
    var omissions = 0
  }

  private let inner: any StorageProvider
  private let probability: Double
  private let listings: ClosedRange<Int>
  private let eligible: @Sendable (ObjectKey) -> Bool
  private let state: Mutex<State>

  public init(
    wrapping inner: any StorageProvider, seed: UInt64 = 0, probability: Double = 0, listings: ClosedRange<Int> = 1...3,
    eligible: @escaping @Sendable (ObjectKey) -> Bool = { _ in true }
  ) {
    precondition(listings.lowerBound > 0, "a hidden object stays hidden for at least one listing")
    self.inner = inner
    self.probability = probability
    self.listings = listings
    self.eligible = eligible
    state = Mutex(State(generator: SeededGenerator(seed: seed)))
  }

  public var capabilities: StorageCapabilities { inner.capabilities }

  /// How many times an object was hidden at random or on purpose.
  public var hidings: Int { state.withLock { $0.hidings } }

  /// How many times a listing left out an object storage holds.
  public var omissions: Int { state.withLock { $0.omissions } }

  public func hide(_ key: ObjectKey, listings: Int) {
    state.withLock { state in
      state.remaining[key] = listings
      state.hidings += 1
    }
  }

  public func setEnabled(_ enabled: Bool) {
    state.withLock { $0.enabled = enabled }
  }

  public func heal() {
    state.withLock { state in
      state.remaining = [:]
      state.omitted = [:]
    }
  }

  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    let page = try await inner.list(prefix: prefix, after: cursor)
    let omitted = state.withLock { state in
      if cursor == nil {
        let due = state.remaining.filter { $0.value > 0 && $0.key.hasPrefix(prefix) }.keys
        for key in due { state.remaining[key, default: 0] -= 1 }
        state.remaining = state.remaining.filter { $0.value > 0 }
        state.omitted[prefix] = Set(due)
      }
      var omitted = state.omitted[prefix] ?? []
      guard state.enabled, probability > 0 else { return omitted }
      for object in page.objects where !omitted.contains(object.key) && eligible(object.key) && state.generator.chance(probability) {
        let count = state.generator.int(in: listings)
        omitted.insert(object.key)
        if count > 1 { state.remaining[object.key] = count - 1 }
        state.hidings += 1
      }
      state.omitted[prefix] = omitted
      return omitted
    }
    let shown = page.objects.filter { !omitted.contains($0.key) }
    state.withLock { $0.omissions += page.objects.count - shown.count }
    return ListPage(objects: shown, next: page.next)
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    try await inner.put(key, data: data, condition: condition)
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
    state.withLock { state in
      for key in keys { state.remaining[key] = nil }
    }
  }

  public func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}
