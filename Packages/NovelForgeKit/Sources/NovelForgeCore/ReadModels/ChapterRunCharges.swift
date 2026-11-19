import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

public struct ChapterRunChargesQuery: Sendable, Hashable {
  public let novel: UUID
  public let chapter: Int

  public init(novel: UUID, chapter: Int) {
    self.novel = novel
    self.chapter = chapter
  }
}

public struct RunCharge: Sendable, Equatable {
  public let job: EntityRef
  public let kind: StoredEnum<NovelJobKind>
  public let run: Int
  public let requested: Date
  public let cost: JobCost
}

/// Newest request first; a fault on the cost tables leaves the runs and the total unavailable, as `JobCosts` does.
public struct ChapterRunCharges: ReadModel {
  public let runs: Derived<[RunCharge]>
  public let total: Derived<JobCost>
  public let faults: [ReadFault]

  public static func load(_ query: ChapterRunChargesQuery, in transaction: ReadTransaction) throws(StoreError) -> ChapterRunCharges {
    let costs = try JobCosts.load(.chapter(novel: query.novel, chapter: query.chapter), in: transaction)
    guard let figures = costs.jobs.value else {
      return ChapterRunCharges(runs: .unavailable(costs.faults), total: .unavailable(costs.faults), faults: costs.faults)
    }
    let entries = try transaction.query { database in
      try JobEntry.filter(Column("novel") == query.novel && Column("chapter") == query.chapter).fetchAll(database)
    }
    let runs = entries.sorted { precedes($1, $0) }.map { entry in
      RunCharge(
        job: entry.ref, kind: entry.jobKind, run: entry.run, requested: Date(timeIntervalSince1970: Double(entry.requested.wallMillis) / 1000),
        cost: figures[entry.ref] ?? .zero)
    }
    return ChapterRunCharges(runs: .available(runs), total: costs.total, faults: costs.faults)
  }

  private static func precedes(_ first: JobEntry, _ second: JobEntry) -> Bool {
    if first.requested != second.requested { return first.requested < second.requested }
    if first.run != second.run { return first.run < second.run }
    return first.job.rawValue.utf8.lexicographicallyPrecedes(second.job.rawValue.utf8)
  }
}
