import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/ai/retrieval/retrieval.service.ts:12
public struct RetrievalHit: Sendable, Equatable {
  public enum Origin: Sendable, Hashable {
    case prose(chapter: Int)
    /// `kind` as the index stores it (`RetrievalLoreKind`); `refKey` is the entity key or the page's `section/slug`.
    case lore(kind: String, refKey: String)
  }

  public let text: String
  /// Higher is better; comparable only between hits of one search.
  public let score: Double
  public let origin: Origin

  public init(text: String, score: Double, origin: Origin) {
    self.text = text
    self.score = score
    self.origin = origin
  }
}

public struct RetrievalResults: Sendable, Equatable {
  public let prose: [RetrievalHit]
  public let lore: [RetrievalHit]
}

/// What one catch-up changed: sources whose indexed text appeared, changed or went, and records that changed without changing what they index.
public struct RetrievalCatchUp: Sendable, Equatable {
  enum Change {
    case added
    case updated
    case removed
    case confirmed
  }

  public private(set) var added = 0
  public private(set) var updated = 0
  public private(set) var removed = 0
  public private(set) var confirmed = 0

  public init(added: Int = 0, updated: Int = 0, removed: Int = 0, confirmed: Int = 0) {
    self.added = added
    self.updated = updated
    self.removed = removed
    self.confirmed = confirmed
  }

  public var isEmpty: Bool { self == RetrievalCatchUp() }

  mutating func count(_ change: Change?) {
    switch change {
    case .added: added += 1
    case .updated: updated += 1
    case .removed: removed += 1
    case .confirmed: confirmed += 1
    case nil: break
    }
  }

  mutating func merge(_ other: RetrievalCatchUp) {
    added += other.added
    updated += other.updated
    removed += other.removed
    confirmed += other.confirmed
  }
}

public enum RetrievalError: ShadowError {
  case store(StoreError)
  /// The record index the catch-up diffs against is faulted for this novel; nothing was changed.
  case indexUnavailable([ReadFault])
  case cancelled

  public var code: String {
    switch self {
    case .store: "retrieval.store"
    case .indexUnavailable: "retrieval.index_unavailable"
    case .cancelled: "retrieval.cancelled"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .store(let error): "The retrieval index could not be read or written: \(error.errorDescription ?? error.code)"
    case .indexUnavailable(let faults): "The record index is unavailable: \(faults.map(\.message).joined(separator: "; "))"
    case .cancelled: "The retrieval catch-up was cancelled."
    }
  }
}

/// Search over a novel's finalized prose and lore (the reference's `RetrievalService`), from an index this device keeps and never syncs. `catchUp(novel:)`
/// brings the index level with the records and is cheap when nothing changed; a search reads whatever the last catch-up left.
public struct NovelRetrieval: Sendable {
  // retrieval.service.ts:22-23
  public static let defaultProseK = 5
  public static let defaultLoreK = 6

  private let store: VaultStore

  public init(store: VaultStore) {
    self.store = store
  }

  @discardableResult
  public func catchUp(novel: UUID) async throws(RetrievalError) -> RetrievalCatchUp {
    let pending = try await read { transaction in try RetrievalIndexer.pending(novel: novel, in: transaction) }
    var outcome = RetrievalCatchUp()
    for start in stride(from: 0, to: pending.count, by: RetrievalIndexer.batchSize) {
      if Task.isCancelled { throw .cancelled }
      let batch = Array(pending[start..<min(start + RetrievalIndexer.batchSize, pending.count)])
      do {
        outcome.merge(try await store.write { transaction in try RetrievalIndexer.refresh(batch, novel: novel, in: transaction.database) })
      } catch {
        throw Self.failure(error)
      }
    }
    return outcome
  }

  /// Leaves out the chapters isolated now, whatever they were when indexed.
  public func searchProse(novel: UUID, query: String, k: Int = defaultProseK) async throws(RetrievalError) -> [RetrievalHit] {
    try await read { transaction in try RetrievalSearch.prose(novel: novel, query: RetrievalQuery(query), k: k, in: transaction) }
  }

  /// `kinds` are matched exactly against `RetrievalLoreKind` raw values; nil or empty searches every kind.
  public func searchLore(novel: UUID, query: String, k: Int = defaultLoreK, kinds: [String]? = nil) async throws(RetrievalError) -> [RetrievalHit] {
    try await read { transaction in try RetrievalSearch.lore(novel: novel, query: RetrievalQuery(query), k: k, kinds: kinds, in: transaction) }
  }

  /// Both searches in one read, so they see the same index and records.
  public func searchProseAndLore(novel: UUID, query: String, proseK: Int = defaultProseK, loreK: Int = defaultLoreK) async throws(RetrievalError) -> RetrievalResults {
    try await read { transaction in
      let parsed = RetrievalQuery(query)
      return RetrievalResults(
        prose: try RetrievalSearch.prose(novel: novel, query: parsed, k: proseK, in: transaction),
        lore: try RetrievalSearch.lore(novel: novel, query: parsed, k: loreK, kinds: nil, in: transaction))
    }
  }

  private func read<T: Sendable>(_ body: @Sendable (ReadTransaction) throws -> T) async throws(RetrievalError) -> T {
    do {
      return try await store.read(body)
    } catch {
      throw Self.failure(error)
    }
  }

  private static func failure(_ error: StoreError) -> RetrievalError {
    guard case .aborted(let cause) = error else { return .store(error) }
    if let retrieval = cause as? RetrievalError { return retrieval }
    return cause is CancellationError ? .cancelled : .store(error)
  }
}
