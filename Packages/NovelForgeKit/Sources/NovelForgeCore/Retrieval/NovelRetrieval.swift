import Foundation
import GRDB
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
  /// Higher is better; comparable only between hits of one list.
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

/// What one embedding pass did: `model` is nil when the system has no embedding model for the novel's text, whose searches then rank by FTS alone.
public struct RetrievalEmbedding: Sendable, Equatable {
  public let model: String?
  public internal(set) var embedded: Int
  /// Texts the model could not embed, marked so they are not tried again until the text or the model changes.
  public internal(set) var failed: Int
  /// False when the limit stopped the pass with rows still to embed.
  public internal(set) var isComplete: Bool

  public init(model: String?, embedded: Int = 0, failed: Int = 0, isComplete: Bool = true) {
    self.model = model
    self.embedded = embedded
    self.failed = failed
    self.isComplete = isComplete
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
    case .cancelled: "The retrieval catch-up or embedding pass was cancelled."
    }
  }
}

/// Search over a novel's finalized prose and lore (the reference's `RetrievalService`), from an index this device keeps and never syncs. `catchUp(novel:)`
/// brings the index level with the records and is cheap when nothing changed; `embedPending(novel:limit:)`, run after it, embeds what the catch-up added
/// when `embedders` has a model for the novel. A search reads whatever the last catch-up and embedding pass left, and ranks by FTS alone until vectors of
/// the novel's current model exist.
public struct NovelRetrieval: Sendable {
  // retrieval.service.ts:22-23
  public static let defaultProseK = 5
  public static let defaultLoreK = 6

  private let store: VaultStore
  private let embedders: (any EmbedderProvider)?

  public init(store: VaultStore, embedders: (any EmbedderProvider)? = nil) {
    self.store = store
    self.embedders = embedders
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

  /// Embeds, in batches of `RetrievalVectors.batchSize` (each its own write), the novel's rows that hold no vector or failure mark of its current model, at
  /// most `limit` of them; every batch write drops the novel's vectors of any other model, so a model change rebuilds and never mixes. Stops with
  /// `cancelled` between batches, discarding a batch embedded after the cancellation. Running it again, or twice at once, converges.
  @discardableResult
  public func embedPending(novel: UUID, limit: Int? = nil) async throws(RetrievalError) -> RetrievalEmbedding {
    guard let embedder = try await embedder(novel: novel) else { return RetrievalEmbedding(model: nil) }
    let (model, dimension) = (embedder.model, embedder.dimension)
    var outcome = RetrievalEmbedding(model: model)
    var budget = max(limit ?? .max, 0)
    for corpus in RetrievalVectors.Corpus.allCases {
      var cursor: Int64 = 0
      while budget > 0 {
        if Task.isCancelled { throw .cancelled }
        let after = cursor
        let size = min(RetrievalVectors.batchSize, budget)
        let batch = try await read { transaction in
          try transaction.query { database in
            try RetrievalVectors.pending(novel: novel, model: model, dimension: dimension, corpus: corpus, after: after, limit: size, in: database)
          }
        }
        guard let last = batch.last else { break }
        let vectors = await embedder.embed(batch.map(\.text))
        if Task.isCancelled { throw .cancelled }
        let stored = try await write { database in
          try RetrievalVectors.store(batch, vectors: vectors, novel: novel, model: model, dimension: dimension, in: database)
        }
        outcome.embedded += stored.embedded
        outcome.failed += stored.failed
        budget -= batch.count
        cursor = last.item
      }
    }
    outcome.isComplete = try await read { transaction in
      try transaction.query { database in try RetrievalVectors.isComplete(novel: novel, model: model, dimension: dimension, in: database) }
    }
    return outcome
  }

  /// Leaves out the chapters isolated now, whatever they were when indexed.
  public func searchProse(novel: UUID, query: String, k: Int = defaultProseK) async throws(RetrievalError) -> [RetrievalHit] {
    let parsed = RetrievalQuery(query)
    let vector = try await queryVector(novel: novel, query: query, parsed: parsed)
    return try await read { transaction in
      try RetrievalSearch.prose(novel: novel, query: parsed, k: k, vector: RetrievalSearch.fusable(vector, novel: novel, in: transaction), in: transaction)
    }
  }

  /// `kinds` are matched exactly against `RetrievalLoreKind` raw values; nil or empty searches every kind.
  public func searchLore(novel: UUID, query: String, k: Int = defaultLoreK, kinds: [String]? = nil) async throws(RetrievalError) -> [RetrievalHit] {
    let parsed = RetrievalQuery(query)
    let vector = try await queryVector(novel: novel, query: query, parsed: parsed)
    return try await read { transaction in
      try RetrievalSearch.lore(novel: novel, query: parsed, k: k, kinds: kinds, vector: RetrievalSearch.fusable(vector, novel: novel, in: transaction), in: transaction)
    }
  }

  /// Both searches in one read with one query embedding, so they see the same index and records.
  public func searchProseAndLore(novel: UUID, query: String, proseK: Int = defaultProseK, loreK: Int = defaultLoreK) async throws(RetrievalError) -> RetrievalResults {
    let parsed = RetrievalQuery(query)
    let vector = try await queryVector(novel: novel, query: query, parsed: parsed)
    return try await read { transaction in
      let fusable = try RetrievalSearch.fusable(vector, novel: novel, in: transaction)
      return RetrievalResults(
        prose: try RetrievalSearch.prose(novel: novel, query: parsed, k: proseK, vector: fusable, in: transaction),
        lore: try RetrievalSearch.lore(novel: novel, query: parsed, k: loreK, kinds: nil, vector: fusable, in: transaction))
    }
  }

  private func embedder(novel: UUID) async throws(RetrievalError) -> (any Embedder)? {
    guard let embedders else { return nil }
    let sample = try await read { transaction in try transaction.query { database in try RetrievalVectors.sample(novel: novel, in: database) } }
    guard let embedder = await embedders.embedder(forSample: sample), embedder.dimension > 0 else { return nil }
    return embedder
  }

  /// The query embedded by the model the novel's vectors were made by, resolved from that stored identity without reading the novel's text; nil, and so
  /// FTS alone, when the query has no terms, the novel has no vectors or rows still waiting for them, the system's model is no longer that one or it could
  /// not embed the query.
  private func queryVector(novel: UUID, query: String, parsed: RetrievalQuery) async throws(RetrievalError) -> RetrievalQueryVector? {
    guard let embedders, parsed.matchExpression != nil else { return nil }
    let stored = try await read { transaction in try transaction.query { database in try RetrievalVectors.storedModel(novel: novel, in: database) } }
    guard let stored, let embedder = await embedders.embedder(forModel: stored), embedder.model == stored, embedder.dimension > 0 else { return nil }
    let dimension = embedder.dimension
    let complete = try await read { transaction in
      try transaction.query { database in try RetrievalVectors.isComplete(novel: novel, model: stored, dimension: dimension, in: database) }
    }
    guard complete, let embedded = await embedder.embed([query]).first, let values = embedded.flatMap({ RetrievalVectors.unit($0, dimension: dimension) }) else { return nil }
    return RetrievalQueryVector(model: stored, values: values)
  }

  private func write<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws(RetrievalError) -> T {
    do {
      return try await store.write { transaction in try body(transaction.database) }
    } catch {
      throw Self.failure(error)
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
