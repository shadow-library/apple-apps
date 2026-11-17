import Foundation
import ShadowStore

public struct LibraryEntry: Sendable, Equatable {
  public let novel: NovelRecord
  public let chapters: Derived<ChapterTally>
}

public struct LibraryList: ReadModel {
  public let novels: [LibraryEntry]
  public let archived: [LibraryEntry]
  public let unreadable: Int
  public let faults: [ReadFault]

  public static func load(_: Void, in transaction: ReadTransaction) throws(StoreError) -> LibraryList {
    let main: NovelList
    let kept: NovelList
    do throws(DomainError) {
      main = try Library.novels(in: transaction)
      kept = try Library.archivedNovels(in: transaction)
    } catch {
      guard case .store(let failure) = error else { throw .invalidChange(error.code) }
      throw failure
    }
    let stored = try FaultRows(in: transaction)
    var faults = Set<ReadFault>()
    func entries(_ list: NovelList) throws(StoreError) -> [LibraryEntry] {
      try list.novels.map { novel throws(StoreError) in
        let report = ReadFaults(novel: novel.id, reading: ChapterTally.tables, from: stored)
        faults.formUnion(report.relevant)
        return LibraryEntry(novel: novel, chapters: try report.section(ChapterTally.tables) { () throws(StoreError) in try ChapterTally.load(novel: novel.id, in: transaction) })
      }
    }
    return LibraryList(
      novels: try entries(main), archived: try entries(kept), unreadable: main.unreadable, faults: faults.sorted { ($0.derivation, $0.message) < ($1.derivation, $1.message) })
  }
}
