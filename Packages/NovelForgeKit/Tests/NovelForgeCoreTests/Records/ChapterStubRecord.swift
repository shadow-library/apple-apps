import Foundation
import ShadowCore
import ShadowStore

@testable import NovelForgeCore

struct ChapterStubRecord: RemovableRecord {
  static let kind = NovelForgeKind.draft

  let key: NovelForgeKey
  let chapter: Int

  var fields: RecordFields<DraftMark> { RecordFields() }

  init(novel: UUID, chapter: Int) throws(NovelForgeKeyError) {
    key = try NovelForgeKey(novel: novel, .draft(chapter: chapter))
    self.chapter = chapter
  }

  init(key: NovelForgeKey, reading reader: FieldReader<DraftMark>) throws(UnreadableReason) {
    guard case .draft(let chapter) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.key = key
    self.chapter = chapter
  }
}
