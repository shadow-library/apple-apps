import Foundation
import ShadowStore

public struct StoryBibleContents: ReadModel {
  public let pages: Derived<StructureSection<PageSummary>>
  public let entities: Derived<StructureSection<EntityRecord>>
  public let faults: [ReadFault]

  private static let tables = [IndexedRecord.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> StoryBibleContents {
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    return StoryBibleContents(
      pages: try report.section(tables) { () throws(StoreError) in
        let records = try PageRecord.indexedListing(novel: novel, in: transaction)
        return StructureSection(items: Pages.summaries(of: records.live), unreadable: records.unreadable)
      },
      entities: try report.section(tables) { () throws(StoreError) in
        let records = try EntityRecord.indexedListing(novel: novel, in: transaction)
        return StructureSection(items: records.live.sorted { JSText.codeUnitPrecedes($0.entity, $1.entity) }, unreadable: records.unreadable)
      },
      faults: report.relevant)
  }
}
