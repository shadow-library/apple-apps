import Foundation
import ShadowCore
import ShadowStore

extension ChapterDrafts {
  /// Keeps the author's text in this device's working copy over the revision the editor rests on, without the head check a save makes. A copy over a moved
  /// head is kept as a version by the next write (D23), so text a refused save would lose, a conflict or a chapter turned final, survives.
  public static func hold(novel: UUID, chapter: Int, title: String?, body: String, base: String, in transaction: inout WriteTransaction) throws(DomainError) {
    try transaction.requireNovel(novel)
    var content: DraftContent
    switch try transaction.draft(novel: novel, chapter: chapter) {
    case .live(let head): content = head.content
    case .removed(let record): content = record.content
    case .absent: content = DraftContent(body: "", source: .known(.handEdited), generator: .known(.human))
    }
    content.title = title ?? content.title
    content.body = normalizeLineEndings(body)
    content.source = .known(.handEdited)
    content.restoredFrom = nil
    content.leakHeldOver = nil
    let copy = DraftWorkingCopy(novel: novel, chapter: chapter, base: base, content: content)
    try storeCall { () throws(StoreError) in try copy.save(in: transaction.database) }
  }
}
