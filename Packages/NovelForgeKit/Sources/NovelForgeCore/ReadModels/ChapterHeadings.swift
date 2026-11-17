import Foundation
import GRDB
import ShadowStore

public struct ChapterHeading: Sendable, Equatable {
  public let title: String?
  public let volume: String?

  public init(title: String?, volume: String?) {
    self.title = title
    self.volume = volume
  }
}

/// Every chapter of a novel that names a title or a volume, from the final chapter, the draft head or the plan head.
public struct ChapterHeadings: ReadModel {
  public let headings: Derived<[Int: ChapterHeading]>
  public let faults: [ReadFault]

  private static let tables = [ChapterHeadingEntry.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChapterHeadings {
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    return ChapterHeadings(
      headings: try report.section(tables) { () throws(StoreError) in
        let entries = try transaction.query { database in try ChapterHeadingEntry.filter(Column("novel") == novel).fetchAll(database) }
        return Dictionary(entries.map { ($0.chapter, ChapterHeading(title: $0.title, volume: $0.volume)) }) { first, _ in first }
      },
      faults: report.relevant)
  }
}
