import Foundation
import GRDB
import ShadowStore

public struct RemovedStory: Sendable, Equatable {
  public let volumes: StructureSection<VolumeRecord>
  public let milestones: StructureSection<MilestoneRecord>
  public let promises: StructureSection<StoryPromise>
  public let secrets: StructureSection<SecretRecord>
}

public struct RemovedBible: Sendable, Equatable {
  public let pages: StructureSection<PageSummary>
  public let entities: StructureSection<EntityRecord>
}

public struct RemovedRecords: ReadModel {
  public let story: Derived<RemovedStory>
  public let bible: Derived<RemovedBible>
  public let faults: [ReadFault]

  static let tables = [IndexedRecord.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> RemovedRecords {
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    return RemovedRecords(
      story: try report.section(tables) { () throws(StoreError) in try story(of: novel, in: transaction) },
      bible: try report.section(tables) { () throws(StoreError) in try bible(of: novel, in: transaction) },
      faults: report.relevant)
  }

  static func story(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> RemovedStory {
    let volumes = try VolumeRecord.removedListing(novel: novel, in: transaction)
    let milestones = try MilestoneRecord.removedListing(novel: novel, in: transaction)
    let threads = try ThreadRecord.removedListing(novel: novel, in: transaction)
    let mysteries = try MysteryRecord.removedListing(novel: novel, in: transaction)
    let secrets = try SecretRecord.removedListing(novel: novel, in: transaction)
    let promises = threads.records.map(StoryPromise.thread).sorted { $0.key < $1.key } + mysteries.records.map(StoryPromise.mystery).sorted { $0.key < $1.key }
    return RemovedStory(
      volumes: StructureSection(
        items: volumes.records.sorted { ($0.ordinal, JSString($0.volume)) < ($1.ordinal, JSString($1.volume)) }, unreadable: volumes.unreadable),
      milestones: StructureSection(items: milestones.records.sorted { JSText.codeUnitPrecedes($0.milestone, $1.milestone) }, unreadable: milestones.unreadable),
      promises: StructureSection(items: promises, unreadable: threads.unreadable + mysteries.unreadable),
      secrets: StructureSection(items: secrets.records.sorted { JSText.codeUnitPrecedes($0.secret, $1.secret) }, unreadable: secrets.unreadable))
  }

  static func bible(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> RemovedBible {
    let pages = try PageRecord.removedListing(novel: novel, in: transaction)
    let entities = try EntityRecord.removedListing(novel: novel, in: transaction)
    return RemovedBible(
      pages: StructureSection(items: Pages.summaries(of: pages.records), unreadable: pages.unreadable),
      entities: StructureSection(items: entities.records.sorted { JSText.codeUnitPrecedes($0.entity, $1.entity) }, unreadable: entities.unreadable))
  }
}

private struct RemovedListing<Record: Sendable> {
  let records: [Record]
  let unreadable: Int
}

extension HeadReadable {
  fileprivate static func removedListing(novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> RemovedListing<Self> {
    let rows = try transaction.query { database in
      try IndexedRecord.filter(Column("novel") == novel && Column("kind") == kind.rawValue && Column("status") == IndexedStatus.removed).fetchAll(database)
    }
    var records = [Self]()
    var unreadable = 0
    for row in rows {
      switch try readHead(row.ref, in: transaction) {
      case .absent, .unreadable(.unknownSection): continue
      case .unreadable: unreadable += 1
      case .readable(let entry): if entry.isRemoved { records.append(entry.record) }
      }
    }
    return RemovedListing(records: records, unreadable: unreadable)
  }
}
