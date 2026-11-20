import Foundation
import ShadowStore
import ShadowText

public struct StoryBibleContents: ReadModel {
  public let pages: Derived<StructureSection<PageSummary>>
  public let entities: Derived<StructureSection<EntityRecord>>
  public let stages: Derived<BibleStages>
  public let faults: [ReadFault]

  private static let tables = [IndexedRecord.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> StoryBibleContents {
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    let listed = try report.section(tables) { () throws(StoreError) in
      let pages = try PageRecord.indexedListing(novel: novel, in: transaction)
      return BibleListing(
        pages: StructureSection(items: Pages.summaries(of: pages.live), unreadable: pages.unreadable), entities: try entities(of: novel, in: transaction),
        volumes: try VolumeRecord.indexedListing(novel: novel, in: transaction).live)
    }
    return StoryBibleContents(
      pages: listed.map(\.pages), entities: listed.map(\.entities),
      stages: listed.map { BibleRoles.stages(pages: $0.pages.items, entities: $0.entities.items, volumes: $0.volumes) }, faults: report.relevant)
  }

  static func entities(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> StructureSection<EntityRecord> {
    let records = try EntityRecord.indexedListing(novel: novel, in: transaction)
    return StructureSection(items: records.live.sorted { JSText.codeUnitPrecedes($0.entity, $1.entity) }, unreadable: records.unreadable)
  }
}

private struct BibleListing: Sendable, Equatable {
  let pages: StructureSection<PageSummary>
  let entities: StructureSection<EntityRecord>
  let volumes: [VolumeRecord]
}
