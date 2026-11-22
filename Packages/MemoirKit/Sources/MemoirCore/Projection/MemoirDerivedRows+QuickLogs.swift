import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// Whether a journal entry, meal or side quest earned its reward, and what replay credited for it, as replay last decided it for the record's id
/// (`RecordIndex.quickLogs`); a weight records no outcome, and a log replay has not taken in (after a halt) has no row.
public struct QuickLogRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_quick_log"
  static let definition = """
    CREATE TABLE mm_derived_quick_log (
      id BLOB PRIMARY KEY, kind TEXT NOT NULL, date TEXT NOT NULL, xp INTEGER, coins INTEGER, CHECK ((xp IS NULL) = (coins IS NULL))
    ) STRICT, WITHOUT ROWID
    """

  public let id: UUID
  public let source: QuickLogSource
  public let date: LocalDate
  /// nil when the log earned nothing.
  public let reward: RewardAmount?

  public var rewarded: Bool { reward != nil }

  init(id: UUID, outcome: QuickLogOutcome) {
    self.id = id
    source = outcome.source
    date = outcome.date
    reward = outcome.reward
  }

  public init(row: Row) throws {
    id = try row.decode(UUID.self, forColumn: "id")
    source = try DerivedColumn.required(row, "kind")
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a quick log row has no date") }
    self.date = date
    switch (try row.decode(Int?.self, forColumn: "xp"), try row.decode(Int?.self, forColumn: "coins")) {
    case (let xp?, let coins?): reward = RewardAmount(xp: xp, coins: coins)
    case (nil, nil): reward = nil
    default: throw StoreError.corruptStore("a quick log row credits XP or coins without the other")
    }
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id
    container["kind"] = source.rawValue
    container["date"] = date.isoString
    container["xp"] = reward?.xp
    container["coins"] = reward?.coins
  }
}

/// The rewards one kind of quick log earned on one day, summed from the hero trail: every grant replay credited, so a side quest whose id two commands
/// named counts each slot it took, which is what the day's cap counts.
public struct QuickLogDayRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_quick_log_day"
  static let definition = """
    CREATE TABLE mm_derived_quick_log_day (
      date TEXT NOT NULL, kind TEXT NOT NULL, rewarded INTEGER NOT NULL, xp INTEGER NOT NULL, coins INTEGER NOT NULL, PRIMARY KEY (date, kind)
    ) STRICT, WITHOUT ROWID
    """
  static let sources: [HeroEventType: QuickLogSource] = [.journal: .journal, .meal: .meal, .sideQuest: .sideQuest]

  public let date: LocalDate
  public let source: QuickLogSource
  public let rewarded: Int
  public let reward: RewardAmount

  init(date: LocalDate, source: QuickLogSource, rewarded: Int, reward: RewardAmount) {
    self.date = date
    self.source = source
    self.rewarded = rewarded
    self.reward = reward
  }

  public init(row: Row) throws {
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a quick log day row has no date") }
    self.date = date
    source = try DerivedColumn.required(row, "kind")
    rewarded = try row.decode(Int.self, forColumn: "rewarded")
    reward = RewardAmount(xp: try row.decode(Int.self, forColumn: "xp"), coins: try row.decode(Int.self, forColumn: "coins"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = date.isoString
    container["kind"] = source.rawValue
    container["rewarded"] = rewarded
    container["xp"] = reward.xp
    container["coins"] = reward.coins
  }

  static func rows(_ events: [HeroEvent]) -> Set<QuickLogDayRow> {
    let grouped = Dictionary(grouping: events.compactMap { event in sources[event.type].map { (date: event.date, source: $0, event: event) } }) {
      DayKind(date: $0.date, source: $0.source)
    }
    return Set(
      grouped.map { key, grants in
        QuickLogDayRow(
          date: key.date, source: key.source, rewarded: grants.count,
          reward: RewardAmount(xp: Exact.sum(grants.map(\.event.xpDelta)), coins: Exact.sum(grants.map(\.event.coinsDelta))))
      })
  }

  private struct DayKind: Hashable {
    let date: LocalDate
    let source: QuickLogSource
  }
}

extension MemoirDerived {
  public static func quickLog(_ id: UUID, in transaction: ReadTransaction) throws(StoreError) -> QuickLogRow? {
    try fetch(QuickLogRow.self, in: transaction) { database in try QuickLogRow.filter(Column("id") == id).fetchOne(database) } ?? nil
  }

  /// The quick logs of `source` dated from `start` through `end`, by date.
  public static func quickLogs(_ source: QuickLogSource, from start: LocalDate, through end: LocalDate, in transaction: ReadTransaction) throws(StoreError)
    -> [QuickLogRow]
  {
    try fetch(QuickLogRow.self, in: transaction) { database in
      try QuickLogRow.filter(Column("kind") == source.rawValue && Column("date") >= start.isoString && Column("date") <= end.isoString)
        .order(Column("date"), Column("id")).fetchAll(database)
    } ?? []
  }

  /// The days from `start` through `end` on which quick logs of `source` earned a reward, by date.
  public static func quickLogDays(_ source: QuickLogSource, from start: LocalDate, through end: LocalDate, in transaction: ReadTransaction) throws(StoreError)
    -> [QuickLogDayRow]
  {
    try fetch(QuickLogDayRow.self, in: transaction) { database in
      try QuickLogDayRow.filter(Column("kind") == source.rawValue && Column("date") >= start.isoString && Column("date") <= end.isoString)
        .order(Column("date")).fetchAll(database)
    } ?? []
  }
}
