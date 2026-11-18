import Foundation
import NovelForgeCore

/// A passage the author commented on, waiting in the composer to ride their next message (apps/novel-forge-web/src/lib/passage-comments.ts:19-27).
nonisolated struct ChatPassageChip: Identifiable, Equatable, Sendable {
  // passage-comments.ts:10-13
  static let limit = 10
  static let commentLimit = 2000

  let passage: ChatTurnPassage
  let firstParagraph: Int
  let lastParagraph: Int
  var isStale = false

  init(_ source: ChatPassageSource, _ selection: ChatPassageSelection, comment: String) {
    passage = source.passage(selection, comment: comment)
    firstParagraph = selection.firstParagraph
    lastParagraph = selection.lastParagraph
  }

  var id: String { Self.id(of: passage) }

  /// passage-comments.ts:87: the same words commented on again replace the earlier comment.
  static func id(of passage: ChatTurnPassage) -> String {
    "\(passage.draftId):\(passage.start):\(passage.end)"
  }
}
