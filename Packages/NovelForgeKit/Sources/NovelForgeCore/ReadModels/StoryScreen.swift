import Foundation
import GRDB
import ShadowStore
import ShadowText

public struct StoryScreen: ReadModel {
  public let structure: StoryStructure
  public let knowledge: KnowledgeLedger
  public let disclosure: ReaderDisclosure
  public let entities: Derived<StructureSection<EntityRecord>>
  public let reveals: PlanRevealReport
  public let next: Derived<Int>
  public let removed: Derived<RemovedStory>
  public let faults: [ReadFault]
  private let names: [JSString: String]

  private static let recordTables = [IndexedRecord.databaseTableName]
  private static let cursorTables = [StoryCursor.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> StoryScreen {
    let stored = try FaultRows(in: transaction)
    let structure = try StoryStructure.load(novel, faults: stored, in: transaction)
    let knowledge = try KnowledgeLedger.load(novel, faults: stored, in: transaction)
    let disclosure = try ReaderDisclosure.load(novel, faults: stored, in: transaction)
    let reveals = try PlanRevealReport.load(novel, faults: stored, in: transaction)
    let report = ReadFaults(novel: novel, reading: recordTables + cursorTables, from: stored)
    let entities = try report.section(recordTables) { () throws(StoreError) in try StoryBibleContents.entities(of: novel, in: transaction) }
    let faults = Set(structure.faults + knowledge.faults + disclosure.faults + reveals.faults + report.relevant)
    return StoryScreen(
      structure: structure, knowledge: knowledge, disclosure: disclosure, entities: entities, reveals: reveals,
      next: try report.section(cursorTables) { () throws(StoreError) in
        try transaction.query { database in try StoryCursor.filter(Column("novel") == novel).fetchOne(database)?.chapter } ?? 1
      },
      removed: try report.section(recordTables) { () throws(StoreError) in try RemovedRecords.story(of: novel, in: transaction) },
      faults: faults.sorted { ($0.derivation, $0.message) < ($1.derivation, $1.message) },
      names: Dictionary((entities.value?.items ?? []).map { (JSString($0.entity), $0.name) }) { first, _ in first })
  }

  public func entityName(_ key: String) -> String? { names[JSString(key)] }
}
