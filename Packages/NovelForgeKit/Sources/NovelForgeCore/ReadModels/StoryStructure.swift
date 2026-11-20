import Foundation
import GRDB
import ShadowStore
import ShadowText

public struct VolumeItem: Sendable, Equatable {
  public let record: VolumeRecord
  public let state: VolumeState
}

public struct MilestoneItem: Sendable, Equatable {
  public let record: MilestoneRecord
  public let state: MilestoneState
  public let plannedChapter: Int?
  public let reachedChapter: Int?
  public let duplicateClaims: [Int]
}

public enum StoryPromise: Sendable, Equatable {
  case thread(ThreadRecord)
  case mystery(MysteryRecord)
}

public struct StructureSection<Item: Sendable & Equatable>: Sendable, Equatable {
  public let items: [Item]
  public let unreadable: Int
}

public struct StoryStructure: ReadModel {
  public let volumes: Derived<StructureSection<VolumeItem>>
  public let milestones: Derived<StructureSection<MilestoneItem>>
  public let promises: Derived<StructureSection<StoryPromise>>
  public let secrets: Derived<StructureSection<SecretRecord>>
  public let faults: [ReadFault]

  private static let volumeTables = [VolumeStateEntry.databaseTableName]
  private static let milestoneTables = [MilestoneStateEntry.databaseTableName, MilestoneClaimEntry.databaseTableName]
  private static let recordTables = [IndexedRecord.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> StoryStructure {
    try load(novel, faults: try FaultRows(in: transaction), in: transaction)
  }

  static func load(_ novel: UUID, faults: FaultRows, in transaction: ReadTransaction) throws(StoreError) -> StoryStructure {
    let report = ReadFaults(novel: novel, reading: volumeTables + milestoneTables + recordTables, from: faults)
    return StoryStructure(
      volumes: try report.section(volumeTables + recordTables) { () throws(StoreError) in try volumes(of: novel, in: transaction) },
      milestones: try report.section(milestoneTables + recordTables) { () throws(StoreError) in try milestones(of: novel, in: transaction) },
      promises: try report.section(recordTables) { () throws(StoreError) in try promises(of: novel, in: transaction) },
      secrets: try report.section(recordTables) { () throws(StoreError) in
        let secrets = try SecretRecord.indexedListing(novel: novel, in: transaction)
        return StructureSection(items: secrets.live.sorted { JSText.codeUnitPrecedes($0.secret, $1.secret) }, unreadable: secrets.unreadable)
      },
      faults: report.relevant)
  }

  private static func volumes(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> StructureSection<VolumeItem> {
    let records = try VolumeRecord.indexedListing(novel: novel, in: transaction)
    let states = try transaction.query { database in try VolumeStateEntry.filter(Column("novel") == novel).fetchAll(database) }
    let byVolume = Dictionary(states.map { (JSString($0.volume), $0.state) }) { first, _ in first }
    let items = records.live.map { VolumeItem(record: $0, state: byVolume[JSString($0.volume)] ?? .notStarted) }
    return StructureSection(
      items: items.sorted { ($0.record.ordinal, JSString($0.record.volume)) < ($1.record.ordinal, JSString($1.record.volume)) }, unreadable: records.unreadable)
  }

  private static func milestones(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> StructureSection<MilestoneItem> {
    let records = try MilestoneRecord.indexedListing(novel: novel, in: transaction)
    let states = try transaction.query { database in try MilestoneStateEntry.filter(Column("novel") == novel).fetchAll(database) }
    let claims = try transaction.query { database in
      try MilestoneClaimEntry.filter(Column("novel") == novel && Column("status") == MilestoneClaimStatus.duplicate.rawValue).fetchAll(database)
    }
    let byMilestone = Dictionary(states.map { (JSString($0.milestone), $0) }) { first, _ in first }
    var duplicates = [JSString: [Int]]()
    for claim in claims { duplicates[JSString(claim.milestone), default: []].append(claim.chapter) }
    let items = records.live.map { record -> MilestoneItem in
      let key = JSString(record.milestone)
      let state = byMilestone[key]
      return MilestoneItem(
        record: record, state: state?.state ?? .open, plannedChapter: state?.plannedChapter, reachedChapter: state?.reachedChapter,
        duplicateClaims: (duplicates[key] ?? []).sorted())
    }
    return StructureSection(items: items.sorted { JSText.codeUnitPrecedes($0.record.milestone, $1.record.milestone) }, unreadable: records.unreadable)
  }

  private static func promises(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> StructureSection<StoryPromise> {
    let threads = try ThreadRecord.indexedListing(novel: novel, in: transaction)
    let mysteries = try MysteryRecord.indexedListing(novel: novel, in: transaction)
    let items = threads.live.map(StoryPromise.thread).sorted { $0.key < $1.key } + mysteries.live.map(StoryPromise.mystery).sorted { $0.key < $1.key }
    return StructureSection(items: items, unreadable: threads.unreadable + mysteries.unreadable)
  }
}

extension StoryPromise {
  var key: JSString {
    switch self {
    case .thread(let record): JSString(record.thread)
    case .mystery(let record): JSString(record.mystery)
    }
  }
}
