import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore

nonisolated struct ChapterLocator: Sendable, Hashable {
  let novel: UUID
  let chapter: Int
}

nonisolated struct ChapterText: Sendable, Equatable {
  var title: String
  var body: String
}

nonisolated struct ChapterContent: ReadModel {
  struct Final: Sendable, Equatable {
    let title: String?
    let body: String
    let note: String?
    let amended: Bool
  }

  struct Draft: Sendable, Equatable {
    let revision: String
    let title: String?
    let body: String
    let summary: String?
    let source: DraftSource?
    let working: ChapterText?

    var head: ChapterText { ChapterText(title: title ?? "", body: body) }
    var editable: ChapterText { working ?? head }
  }

  enum Body: Sendable, Equatable {
    case missing
    case unreadable
    case final(Final)
    case draft(Draft)
  }

  let chapter: Int
  let body: Body
  let row: ChapterRow?
  let kept: ChapterText?

  static func load(_ locator: ChapterLocator, in transaction: ReadTransaction) throws(StoreError) -> ChapterContent {
    let row = try ChapterList.load(locator.novel, in: transaction).rows.value?.first { $0.chapter == locator.chapter }
    let copy = try DraftWorkingCopy.read(novel: locator.novel, chapter: locator.chapter, in: transaction.database)
    let body = try body(of: locator, copy: copy, in: transaction)
    return ChapterContent(chapter: locator.chapter, body: body, row: row, kept: kept(copy, beside: body))
  }

  private static func kept(_ copy: DraftWorkingCopy?, beside body: Body) -> ChapterText? {
    guard let copy else { return nil }
    let text = ChapterText(title: copy.content.title ?? "", body: copy.content.body)
    switch body {
    case .draft(let draft): return copy.base == draft.revision ? nil : text
    case .final, .missing: return text
    case .unreadable: return nil
    }
  }

  private static func body(of locator: ChapterLocator, copy: DraftWorkingCopy?, in transaction: ReadTransaction) throws(StoreError) -> Body {
    guard let finalRef = try? FinalChapterRecord.ref(novel: locator.novel, chapter: locator.chapter),
      let draftRef = try? DraftRecord.ref(novel: locator.novel, chapter: locator.chapter)
    else { return .missing }
    switch try FinalChapterRecord.read(finalRef, in: transaction) {
    case .unreadable: return .unreadable
    case .readable(let entry) where !entry.isRemoved:
      let text = entry.record.text
      return .final(Final(title: text.title, body: text.body, note: text.note, amended: entry.record.amendment != nil))
    case .readable, .absent: break
    }
    return try draft(at: draftRef, copy: copy, in: transaction)
  }

  private static func draft(at ref: EntityRef, copy: DraftWorkingCopy?, in transaction: ReadTransaction) throws(StoreError) -> Body {
    switch try DraftRecord.read(ref, in: transaction) {
    case .absent: return .missing
    case .unreadable: return .unreadable
    case .readable(let entry):
      guard !entry.isRemoved else { return .missing }
      guard let revision = try DraftRecord.history(ref, in: transaction).history?.head else { return .unreadable }
      let working = copy.flatMap { $0.base == revision ? ChapterText(title: $0.content.title ?? "", body: $0.content.body) : nil }
      let content = entry.record.content
      return .draft(Draft(revision: revision, title: content.title, body: content.body, summary: content.summary, source: content.source.known, working: working))
    }
  }
}
