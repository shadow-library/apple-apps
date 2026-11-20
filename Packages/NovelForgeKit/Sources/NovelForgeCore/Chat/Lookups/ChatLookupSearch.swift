import Foundation
import OSLog
import ShadowCore
import ShadowStore

private let logger = Logger(category: "chat.lookups")

private let noLore = "No lore found."
private let noProse = "No prose found."

/// Answers `search_lore` and `search_prose` from the retrieval index, brought level with the records first so a sentence an amend removed is never found.
struct ChatLookupSearch: Sendable {
  let store: VaultStore
  let novel: UUID
  let embedders: (any EmbedderProvider)?

  /// One answer per retrieval request, nil for every other request; the index is caught up once, however many searches the round holds.
  func answers(for requests: [ChatLookupRequest?]) async throws(CancellationError) -> [String?] {
    guard requests.contains(where: { $0?.isRetrieval == true }) else { return requests.map { _ in nil } }
    let retrieval = NovelRetrieval(store: store, embedders: embedders)
    let current = try await catchUp(retrieval)
    var answers: [String?] = []
    for request in requests {
      if Task.isCancelled { throw CancellationError() }
      switch request {
      case .searchLore(let query, let kinds)?: answers.append(current ? try await lore(retrieval, query: query, kinds: kinds) : noLore)
      case .searchProse(let query, let k)?: answers.append(current ? try await prose(retrieval, query: query, k: k) : noProse)
      default: answers.append(nil)
      }
    }
    return answers
  }

  private func catchUp(_ retrieval: NovelRetrieval) async throws(CancellationError) -> Bool {
    do {
      try await retrieval.catchUp(novel: novel)
      return true
    } catch .cancelled {
      throw CancellationError()
    } catch {
      logger.error("Retrieval catch-up failed; answering with no results code=\(error.code, privacy: .public)")
      return false
    }
  }

  // tools/search-lore.tool.ts:21-23
  private func lore(_ retrieval: NovelRetrieval, query: String, kinds: [String]?) async throws(CancellationError) -> String {
    let hits = try await search { () async throws(RetrievalError) in try await retrieval.searchLore(novel: novel, query: query, k: NovelRetrieval.defaultLoreK, kinds: kinds) }
    guard !hits.isEmpty else { return noLore }
    return hits.map { hit in
      guard case .lore(let kind, let refKey) = hit.origin else { return hit.text }
      return "\(kind):\(refKey) — \(hit.text)"
    }.joined(separator: "\n")
  }

  // tools/search-prose.tool.ts:21-23
  private func prose(_ retrieval: NovelRetrieval, query: String, k: Int?) async throws(CancellationError) -> String {
    let hits = try await search { () async throws(RetrievalError) in
      try await retrieval.searchProse(novel: novel, query: query, k: min(k ?? NovelRetrieval.defaultProseK, ChatLookups.maximumProseK))
    }
    guard !hits.isEmpty else { return noProse }
    return hits.map { hit in
      guard case .prose(let chapter) = hit.origin else { return hit.text }
      return "[Ch \(chapter)] \(hit.text)"
    }.joined(separator: "\n---\n")
  }

  private func search(_ body: () async throws(RetrievalError) -> [RetrievalHit]) async throws(CancellationError) -> [RetrievalHit] {
    do {
      return try await body()
    } catch .cancelled {
      throw CancellationError()
    } catch {
      logger.error("Retrieval search failed; answering with no results code=\(error.code, privacy: .public)")
      return []
    }
  }
}
