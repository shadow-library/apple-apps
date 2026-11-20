import Foundation
import GRDB
import ShadowStore
import ShadowText

public struct SecretRevealViolation: Sendable, Equatable {
  public let chapter: Int
  public let missing: [String]
}

// apps/novel-forge-server/src/common/plan-state.ts:91: each plan's verdict and the secrets its knowledge contract reveals too early
public struct PlanRevealReport: ReadModel {
  public let plans: Derived<[PlanRevealEntry]>
  public let faults: [ReadFault]

  static let tables = [PlanRevealEntry.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> PlanRevealReport {
    try load(novel, faults: try FaultRows(in: transaction), in: transaction)
  }

  static func load(_ novel: UUID, faults: FaultRows, in transaction: ReadTransaction) throws(StoreError) -> PlanRevealReport {
    let report = ReadFaults(novel: novel, reading: tables, from: faults)
    return PlanRevealReport(plans: try report.section(tables) { () throws(StoreError) in try plans(of: novel, in: transaction) }, faults: report.relevant)
  }

  static func plans(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [PlanRevealEntry] {
    try transaction.query { database in try PlanRevealEntry.filter(Column("novel") == novel).order(Column("chapter")).fetchAll(database) }
  }

  public var violatedChapters: Derived<[Int]> {
    plans.map { entries in entries.filter { $0.status == .violated }.map(\.chapter) }
  }

  public func violations(of secret: String) -> Derived<[SecretRevealViolation]> {
    let key = JSString(secret)
    return plans.map { entries in
      entries.flatMap { entry in
        entry.violations.filter { JSString($0.fact) == key }.map { SecretRevealViolation(chapter: entry.chapter, missing: $0.missing) }
      }
    }
  }
}
