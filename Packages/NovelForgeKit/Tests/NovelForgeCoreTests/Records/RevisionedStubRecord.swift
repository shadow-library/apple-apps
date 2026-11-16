import Foundation
import ShadowCore
import ShadowStore

@testable import NovelForgeCore

struct RevisionedStubRecord: DocumentRecord, RemovableRecord {
  typealias Body = PageContent
  typealias Mark = DraftMark

  static let kind = NovelForgeKind.draft

  let key: NovelForgeKey
  var content: PageContent

  init(novel: UUID, chapter: Int, content: PageContent = PageContent()) throws(NovelForgeKeyError) {
    key = try NovelForgeKey(novel: novel, .draft(chapter: chapter))
    self.content = content
  }

  init(key: NovelForgeKey, reading reader: FieldReader<DocumentField>) throws(UnreadableReason) {
    guard case .draft = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.key = key
    content = try reader.head()
  }
}
