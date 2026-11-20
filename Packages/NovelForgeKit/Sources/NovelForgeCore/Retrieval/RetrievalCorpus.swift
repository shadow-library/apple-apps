import Foundation
import ShadowStore

/// The `kind` the reference stores on a lore row; `search_lore` filters by these strings.
public enum RetrievalLoreKind: String, CaseIterable, Sendable {
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-finalization.graph.ts:243, every entity type alike
  case character
  // apps/novel-forge-server/src/modules/ai/graphs/bible-builder.graph.ts:267
  case bibleDoc = "bible_doc"
}

/// What one record contributes to the index: a final chapter's prose, chunked when stored, or one lore row.
enum RetrievalContent: Sendable, Equatable {
  case prose(chapter: Int, body: String)
  case lore(kind: RetrievalLoreKind, refKey: String, text: String)
}

/// The records the index is built from, one source each: every readable final chapter, entity and Story Bible page of the novel.
enum RetrievalCorpus {
  static let kinds: [NovelForgeKind] = [.finalChapter, .entity, .page]

  /// Raised whenever what a record contributes changes meaning (the chunker, the lore texts, the pages left out), so every source is read again.
  static let version = 1

  private static let hashDomain = "com.shadow.library.novelforgekit.retrieval-source"

  static func content(of ref: EntityRef, in transaction: ReadTransaction) throws(StoreError) -> RetrievalContent? {
    switch NovelForgeKind(ref.kind) {
    case .finalChapter: try prose(ref, in: transaction)
    case .entity: try entityLore(ref, in: transaction)
    case .page: try pageLore(ref, in: transaction)
    default: nil
    }
  }

  /// The record digest a source records: a source read under another corpus version never matches, so a version change reads every record again.
  static func stamp(_ digest: String, version: Int) -> String {
    "\(version):\(digest)"
  }

  /// Changes with the indexed text, its metadata and the corpus version; computed before chunking, so a record whose text stayed is never re-chunked.
  static func hash(_ content: RetrievalContent, version: Int) -> String {
    let parts: [String] =
      switch content {
      case .prose(let chapter, let body): ["prose", String(chapter), body]
      case .lore(let kind, let refKey, let text): ["lore", kind.rawValue, refKey, text]
      }
    return sha256Hex(([hashDomain, String(version)] + parts).map { "\($0.utf8.count):\($0)" }.joined())
  }

  /// apps/novel-forge-server/src/modules/ai/retrieval/indexing.service.ts:126-128: a chapter with no prose is left out.
  private static func prose(_ ref: EntityRef, in transaction: ReadTransaction) throws(StoreError) -> RetrievalContent? {
    guard case .readable(let entry) = try FinalChapterRecord.read(ref, in: transaction), !entry.isRemoved else { return nil }
    let body = entry.record.text.body
    guard !body.isEmpty else { return nil }
    return .prose(chapter: entry.record.chapter, body: body)
  }

  // apps/novel-forge-server/src/modules/ai/graphs/chapter-finalization.graph.ts:238-241
  private static func entityLore(_ ref: EntityRef, in transaction: ReadTransaction) throws(StoreError) -> RetrievalContent? {
    guard case .readable(let entry) = try EntityRecord.read(ref, in: transaction), !entry.isRemoved else { return nil }
    let entity = entry.record
    let text = [entity.name, entity.notes, entity.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    guard !text.isEmpty else { return nil }
    return .lore(kind: .character, refKey: entity.entity, text: text)
  }

  // apps/novel-forge-server/src/modules/ai/graphs/bible-builder.graph.ts:264-267
  private static func pageLore(_ ref: EntityRef, in transaction: ReadTransaction) throws(StoreError) -> RetrievalContent? {
    guard case .readable(let entry) = try PageRecord.readHead(ref, in: transaction), !entry.isRemoved else { return nil }
    let page = entry.record
    guard let body = page.content.body, !body.isEmpty, !isPlannerOnlyBibleDoc(BibleDocAddress(section: page.section.rawValue, slug: page.slug)) else { return nil }
    return .lore(kind: .bibleDoc, refKey: "\(page.section.rawValue)/\(page.slug)", text: body)
  }
}
