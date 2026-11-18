import Foundation
import ShadowStore

public enum ChatPassageRefusal: Error, Equatable, Sendable {
  case empty
  case tooLong
  /// The range splits a character the body stores as two UTF-16 code units.
  case unmapped
}

/// A selection of a draft's body in UTF-16 code units, with the paragraphs it starts and ends in (apps/novel-forge-web/src/lib/passage-comments.ts:84-103).
public struct ChatPassageSelection: Equatable, Sendable {
  public let start: Int
  public let end: Int
  public let quote: String
  public let firstParagraph: Int
  public let lastParagraph: Int
}

/// A chapter's draft exactly as a chat turn anchors passages to it on this device (`ChatTurnDrafts.read`), for selecting the passages a message comments on.
public struct ChatPassageSource: Equatable, Sendable {
  // apps/novel-forge-web/src/lib/passage-comments.ts:12
  public static let maxQuoteLength = maxPassageQuoteChars

  public let chapter: Int
  public let draftId: String
  public let revision: Int
  public let body: String
  public let isolated: Bool

  init(_ draft: ChatTurnDraft) {
    let passage = draft.passageDraft
    self.init(chapter: passage.chapter, draftId: passage.id, revision: passage.revision, body: passage.body, isolated: passage.isolated)
  }

  init(chapter: Int, draftId: String, revision: Int, body: String, isolated: Bool) {
    self.chapter = chapter
    self.draftId = draftId
    self.revision = revision
    self.body = body
    self.isolated = isolated
  }

  /// Nil where the turn would find no draft: missing, removed or unreadable.
  public static func load(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> ChatPassageSource? {
    try ChatTurnDrafts.read([chapter], novel: novel, in: transaction)[chapter].map(ChatPassageSource.init)
  }

  /// apps/novel-forge-web/src/lib/chapter-reader.ts:172: the selected words exactly as the body holds them, at most 2,000 code units.
  public func select(_ range: NSRange) -> Result<ChatPassageSelection, ChatPassageRefusal> {
    guard range.location != NSNotFound, range.length > 0, range.location >= 0, range.location + range.length <= body.jsLength else { return .failure(.empty) }
    let (start, end) = (range.location, range.location + range.length)
    let units = body.jsSliceCodeUnits(start, end)
    let quote = String(decoding: units, as: UTF16.self)
    guard quote.utf16.elementsEqual(units) else { return .failure(.unmapped) }
    guard quote.jsTrim().jsLength > 0 else { return .failure(.empty) }
    guard units.count <= Self.maxQuoteLength else { return .failure(.tooLong) }
    return .success(
      ChatPassageSelection(
        start: start, end: end, quote: quote, firstParagraph: paragraphAt(body, offset: start), lastParagraph: paragraphAt(body, offset: end - 1)))
  }

  /// passage-comments.ts:84-103
  public func passage(_ selection: ChatPassageSelection, comment: String) -> ChatTurnPassage {
    ChatTurnPassage(
      chapter: chapter, draftId: draftId, revision: revision, start: selection.start, end: selection.end, passageHash: passageHash(selection.quote),
      quote: selection.quote, comment: comment.jsTrim())
  }

  /// passage-comments.ts:154-161 over the engine's own anchoring: the indices of `passages` their drafts, as they stand, no longer hold.
  public static func unresolved(_ passages: [ChatTurnPassage], novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [Int] {
    let drafts = try ChatTurnDrafts.read(passages.map(\.chapter), novel: novel, in: transaction)
    return passages.indices.filter { index in
      do throws(ChatTurnError) {
        _ = try ChatTurnDrafts.resolve([passages[index]], drafts: drafts)
        return false
      } catch {
        return true
      }
    }
  }
}
