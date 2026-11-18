import Foundation
import GRDB
import ShadowStore

public enum NovelExport {
  public static func manuscript(novel: UUID, in transaction: ReadTransaction) throws(ExportError) -> String {
    try Manuscript.markdown(of: finalChapters(of: novel, in: transaction))
  }

  /// novel-package.service.ts:142-159: the final chapters, else the drafts, so a novel that has finalized nothing still exports.
  public static func package(novel: UUID, in transaction: ReadTransaction) throws(ExportError) -> NovelPackage {
    let info = try exportNovel(novel, in: transaction)
    var chapters = try finalChapters(of: novel, in: transaction)
    if !chapters.contains(where: { !$0.content.jsTrim().isEmpty }) { chapters = try draftChapters(of: novel, in: transaction) }
    return try NovelPackage.build(novel: info, chapters: chapters)
  }

  private static func exportNovel(_ novel: UUID, in transaction: ReadTransaction) throws(ExportError) -> ExportNovel {
    guard case .readable(let entry) = try storeCall({ () throws(StoreError) in try NovelRecord.read(id: novel, in: transaction) }), !entry.isRemoved else {
      throw .novelNotFound(novel)
    }
    let record = entry.record
    return ExportNovel(id: record.id, name: record.name, title: record.title, brief: record.brief, premise: record.premise, themes: record.themes)
  }

  private static func finalChapters(of novel: UUID, in transaction: ReadTransaction) throws(ExportError) -> [ExportChapter] {
    let listing = try storeCall { () throws(StoreError) in try FinalChapterRecord.listing(novel: novel, in: transaction) }
    guard listing.unreadable == 0 else { throw .unreadableChapters(count: listing.unreadable) }
    return listing.entries.map { entry in
      let text = entry.record.text
      return ExportChapter(number: entry.record.chapter, title: text.title, content: text.body)
    }
  }

  private static func draftChapters(of novel: UUID, in transaction: ReadTransaction) throws(ExportError) -> [ExportChapter] {
    let listing = try storeCall { () throws(StoreError) in try DraftRecord.indexedListing(novel: novel, in: transaction) }
    guard listing.unreadable == 0 else { throw .unreadableChapters(count: listing.unreadable) }
    return try listing.live.map { record throws(ExportError) in
      let content = try storeCall { () throws(StoreError) in try ChatTurnDrafts.readThrough(record.content, novel: novel, chapter: record.chapter, in: transaction) }
      return ExportChapter(number: record.chapter, title: content.title, content: content.body)
    }
  }

  private static func storeCall<Value>(_ body: () throws(StoreError) -> Value) throws(ExportError) -> Value {
    do throws(StoreError) {
      return try body()
    } catch {
      throw .store(error)
    }
  }
}

extension VaultStore {
  public func exportManuscript(novel: UUID) async throws(ExportError) -> String {
    try await readExport { transaction throws(ExportError) in try NovelExport.manuscript(novel: novel, in: transaction) }
  }

  public func exportPackage(novel: UUID) async throws(ExportError) -> NovelPackage {
    try await readExport { transaction throws(ExportError) in try NovelExport.package(novel: novel, in: transaction) }
  }

  private func readExport<Value: Sendable>(_ body: @Sendable (ReadTransaction) throws(ExportError) -> Value) async throws(ExportError) -> Value {
    do {
      return try await read { transaction in try body(transaction) }
    } catch {
      if case .aborted(let cause) = error, let export = cause as? ExportError { throw export }
      throw .store(error)
    }
  }
}
