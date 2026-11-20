import Foundation
import GRDB
import ShadowStore
import ShadowText

public struct KnowledgeLedger: ReadModel {
  public let entries: Derived<[CharacterKnowledgeEntry]>
  public let faults: [ReadFault]

  private static let tables = [CharacterKnowledgeEntry.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> KnowledgeLedger {
    try load(novel, faults: try FaultRows(in: transaction), in: transaction)
  }

  static func load(_ novel: UUID, faults: FaultRows, in transaction: ReadTransaction) throws(StoreError) -> KnowledgeLedger {
    let report = ReadFaults(novel: novel, reading: tables, from: faults)
    return KnowledgeLedger(
      entries: try report.section(tables) { () throws(StoreError) in
        let rows = try transaction.query { database in try CharacterKnowledgeEntry.filter(Column("novel") == novel).fetchAll(database) }
        return rows.sorted { left, right in
          guard left.chapter == right.chapter else { return left.chapter < right.chapter }
          guard JSString(left.entity) == JSString(right.entity) else { return JSText.codeUnitPrecedes(left.entity, right.entity) }
          return JSText.codeUnitPrecedes(left.fact, right.fact)
        }
      },
      faults: report.relevant)
  }
}

extension KnowledgeLedger {
  public func facts(known entity: String) -> Derived<[CharacterKnowledgeEntry]> {
    filtered { JSString($0.entity) == JSString(entity) }
  }

  public func knowers(of fact: String) -> Derived<[CharacterKnowledgeEntry]> {
    filtered { JSString($0.fact) == JSString(fact) }
  }

  private func filtered(_ matches: (CharacterKnowledgeEntry) -> Bool) -> Derived<[CharacterKnowledgeEntry]> {
    switch entries {
    case .available(let all): .available(all.filter(matches))
    case .unavailable(let faults): .unavailable(faults)
    }
  }
}
