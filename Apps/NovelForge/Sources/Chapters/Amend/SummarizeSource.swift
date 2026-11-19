import Foundation
import NovelForgeCore
import ShadowStore

nonisolated struct SummarySource: Sendable, Equatable {
  let isFinal: Bool
  let isolated: Bool
  let summary: String
  let body: String
  let revision: String?

  var hasProse: Bool { !body.allSatisfy(\.isWhitespace) }

  static func load<Transaction: StateReading & ~Copyable>(
    novel: UUID, chapter: Int, copy: DraftWorkingCopy?, in transaction: borrowing Transaction
  ) throws(StoreError) -> SummarySource? {
    guard let finalRef = try? FinalChapterRecord.ref(novel: novel, chapter: chapter), let draftRef = try? DraftRecord.ref(novel: novel, chapter: chapter) else { return nil }
    if case .readable(let entry) = try FinalChapterRecord.read(finalRef, in: transaction), !entry.isRemoved {
      let record = entry.record
      return SummarySource(isFinal: true, isolated: record.canon.isolated, summary: record.text.summary ?? "", body: record.text.body, revision: nil)
    }
    guard case .readable(let entry) = try DraftRecord.read(draftRef, in: transaction), !entry.isRemoved,
      let head = try DraftRecord.history(draftRef, in: transaction).history?.head
    else { return nil }
    let content = entry.record.content
    let body = copy.flatMap { $0.base == head ? $0.content.body : nil } ?? content.body
    return SummarySource(isFinal: false, isolated: content.isolated, summary: content.summary ?? "", body: body, revision: head)
  }
}
