import Foundation
import GRDB
import ShadowStore

public enum ChapterStage: Sendable, Equatable {
  case planned
  case drafted
  case approved
  case final
}

public struct ChapterRow: Sendable, Equatable {
  public let chapter: Int
  public let stage: ChapterStage
  public let review: DraftReviewState?
  public let approval: UUID?
  public let approvalKind: ApprovalKind?
  public let stale: StaleCause?
  public let planStale: StaleCause?
  public let hasUnreadableCanon: Bool
}

public struct ChapterList: ReadModel {
  public let rows: Derived<[ChapterRow]>
  public let reveals: Derived<[Int: PlanRevealStatus]>
  public let next: Derived<Int>
  public let faults: [ReadFault]

  private static let rowTables = [ChapterLifecycleEntry.databaseTableName, FinalChapterEntry.databaseTableName]
  private static let revealTables = [PlanRevealEntry.databaseTableName]
  private static let cursorTables = [StoryCursor.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChapterList {
    let report = try ReadFaults(novel: novel, reading: rowTables + revealTables + cursorTables, in: transaction)
    return ChapterList(
      rows: try report.section(rowTables) { () throws(StoreError) in try rows(of: novel, in: transaction) },
      reveals: try report.section(revealTables) { () throws(StoreError) in
        let entries = try transaction.query { database in try PlanRevealEntry.filter(Column("novel") == novel).fetchAll(database) }
        return Dictionary(entries.map { ($0.chapter, $0.status) }) { first, _ in first }
      },
      next: try report.section(cursorTables) { () throws(StoreError) in
        try transaction.query { database in try StoryCursor.filter(Column("novel") == novel).fetchOne(database)?.chapter } ?? 1
      },
      faults: report.relevant)
  }

  private static func rows(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [ChapterRow] {
    let lifecycle = try transaction.query { database in try ChapterLifecycleEntry.filter(Column("novel") == novel).order(Column("chapter")).fetchAll(database) }
    let unreadable = try transaction.query { database in
      try FinalChapterEntry.filter(Column("novel") == novel && Column("readable") == false).fetchAll(database).map(\.chapter)
    }
    let unreadableCanons = Set(unreadable)
    return lifecycle.map { entry in
      ChapterRow(
        chapter: entry.chapter, stage: stage(of: entry), review: entry.review, approval: entry.approval, approvalKind: entry.approvalKind, stale: entry.stale,
        planStale: entry.planStale, hasUnreadableCanon: unreadableCanons.contains(entry.chapter))
    }
  }

  private static func stage(of entry: ChapterLifecycleEntry) -> ChapterStage {
    if entry.isFinal { return .final }
    guard entry.draft != nil else { return .planned }
    return entry.review == .approved ? .approved : .drafted
  }
}
