import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// One of a day's Comeback events, as the reference's `comeback_events` keys it by date and kind.
public struct ComebackRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_comeback"
  static let definition = """
    CREATE TABLE mm_derived_comeback (
      date TEXT NOT NULL, kind TEXT NOT NULL, xp_bonus INTEGER NOT NULL, coin_bonus INTEGER NOT NULL, PRIMARY KEY (date, kind)
    ) STRICT, WITHOUT ROWID
    """

  public let date: LocalDate
  public let kind: ComebackEventKind
  public let xpBonus: Int
  public let coinBonus: Int

  init(date: LocalDate, event: ComebackEvent) {
    self.date = date
    kind = event.kind
    xpBonus = event.xpBonus
    coinBonus = event.coinBonus
  }

  public init(row: Row) throws {
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a comeback row has no date") }
    self.date = date
    kind = try DerivedColumn.required(row, "kind")
    xpBonus = try row.decode(Int.self, forColumn: "xp_bonus")
    coinBonus = try row.decode(Int.self, forColumn: "coin_bonus")
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = date.isoString
    container["kind"] = kind.rawValue
    container["xp_bonus"] = xpBonus
    container["coin_bonus"] = coinBonus
  }
}

/// An occurrence whose break a streak shield bridged; it stays when the occurrence's log is deleted, as the reference's `shield_consumptions` does.
public struct ShieldConsumptionRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_shield_consumption"
  static let definition = """
    CREATE TABLE mm_derived_shield_consumption (date TEXT NOT NULL, quest BLOB NOT NULL, PRIMARY KEY (date, quest)) STRICT, WITHOUT ROWID
    """

  public let occurrence: Occurrence

  init(_ occurrence: Occurrence) {
    self.occurrence = occurrence
  }

  public init(row: Row) throws {
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a shield consumption row has no date") }
    occurrence = Occurrence(quest: try row.decode(UUID.self, forColumn: "quest"), date: date)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = occurrence.date.isoString
    container["quest"] = occurrence.quest
  }
}

extension MemoirDerived {
  public static func comebacks(in transaction: ReadTransaction) throws(StoreError) -> [ComebackRow] {
    try fetch(ComebackRow.self, in: transaction) { database in try ComebackRow.order(Column("date"), Column("kind")).fetchAll(database) } ?? []
  }

  public static func shieldConsumptions(in transaction: ReadTransaction) throws(StoreError) -> [ShieldConsumptionRow] {
    try fetch(ShieldConsumptionRow.self, in: transaction) { database in try ShieldConsumptionRow.order(Column("date"), Column("quest")).fetchAll(database) } ?? []
  }

  /// Every quest log, by date and quest.
  public static func questLogs(in transaction: ReadTransaction) throws(StoreError) -> [QuestLogRow] {
    try fetch(QuestLogRow.self, in: transaction) { database in try QuestLogRow.order(Column("date"), Column("quest")).fetchAll(database) } ?? []
  }

  /// Every day the walk opened, by date.
  public static func days(in transaction: ReadTransaction) throws(StoreError) -> [DayRow] {
    try fetch(DayRow.self, in: transaction) { database in try DayRow.order(Column("date")).fetchAll(database) } ?? []
  }

  public static func recoveries(in transaction: ReadTransaction) throws(StoreError) -> [RecoveryRow] {
    try fetch(RecoveryRow.self, in: transaction) { database in try RecoveryRow.order(Column("date")).fetchAll(database) } ?? []
  }

  public static func returners(in transaction: ReadTransaction) throws(StoreError) -> [ReturnerRow] {
    try fetch(ReturnerRow.self, in: transaction) { database in try ReturnerRow.order(Column("date")).fetchAll(database) } ?? []
  }
}
