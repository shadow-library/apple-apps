import Foundation
import OSLog
import ShadowCore

/// Where the outline pack's `prose_retrieved` and `lore_retrieved` come from. The plan step builds its pack, these hits included, each time it runs and
/// checkpoints only the vetted plan, so a resumed step searches again over the records as they are then, as every other section of the pack reads them.
struct OutlineRetrieval: Sendable {
  static let logger = Logger(category: "outline.retrieval")

  let search: @Sendable (_ novel: UUID, _ query: String) async throws -> RetrievalResults

  /// The device's index, brought level with the records before the search, so the pack never recalls text the records no longer hold; the catch-up is a
  /// digest comparison when the background upkeep already did it.
  static func index(_ retrieval: NovelRetrieval) -> OutlineRetrieval {
    OutlineRetrieval { novel, query in
      try await retrieval.catchUp(novel: novel)
      return try await retrieval.searchProseAndLore(novel: novel, query: query)
    }
  }

  /// context-assembler.service.ts:662-664: a failed search reads as no hits.
  func recall(novel: UUID, query: String) async -> RetrievalResults {
    do {
      return try await search(novel, query)
    } catch {
      let code = (error as? any ShadowError)?.code ?? String(describing: type(of: error))
      Self.logger.error("The outline pack's retrieval failed; the pack goes without it code=\(code, privacy: .public)")
      return RetrievalResults(prose: [], lore: [])
    }
  }
}

extension RetrievalHit {
  /// context-assembler.service.ts:667,671: `Ch <chapter>` for prose, `<kind>:<refKey>` for lore.
  var outlineLabel: String {
    switch origin {
    case .prose(let chapter): "Ch \(chapter)"
    case .lore(let kind, let refKey): "\(kind):\(refKey)"
    }
  }
}
