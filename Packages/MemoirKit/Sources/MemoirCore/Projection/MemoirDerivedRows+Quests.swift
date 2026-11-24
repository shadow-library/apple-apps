import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// A quest's schedule as its commands last left it, with its streak; a deleted quest stays, inactive, so its logs keep naming it.
public struct QuestRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_quest"
  static let definition = """
    CREATE TABLE mm_derived_quest (
      quest BLOB PRIMARY KEY, created_order INTEGER NOT NULL, created_on TEXT NOT NULL, schedule TEXT NOT NULL, current_days INTEGER NOT NULL,
      longest_days INTEGER NOT NULL, shields INTEGER NOT NULL, toward_shield INTEGER NOT NULL, pending_shields INTEGER NOT NULL, run_start TEXT, last_counted TEXT
    ) STRICT, WITHOUT ROWID
    """

  public let id: UUID
  public let createdOrder: Int
  public let createdOn: LocalDate
  public let schedule: QuestSchedule
  public let streak: StreakState
  public let runStartDate: LocalDate?
  public let lastCountedDate: LocalDate?

  init(_ quest: ReplayQuest, streak: QuestStreak?) {
    id = quest.id
    createdOrder = quest.createdOrder
    createdOn = quest.createdOn
    schedule = quest.schedule
    self.streak = streak?.state ?? .empty
    runStartDate = streak?.runStartDate
    lastCountedDate = streak?.lastCountedDate
  }

  public init(row: Row) throws {
    id = try row.decode(UUID.self, forColumn: "quest")
    createdOrder = try row.decode(Int.self, forColumn: "created_order")
    guard let createdOn = try DerivedColumn.date(row, "created_on") else { throw StoreError.corruptStore("a quest row has no creation day") }
    self.createdOn = createdOn
    let text = try row.decode(String.self, forColumn: "schedule")
    guard let schedule = try? JSONDecoder().decode(QuestSchedule.self, from: Data(text.utf8)) else { throw StoreError.corruptStore("a quest row holds an unreadable schedule") }
    self.schedule = schedule
    streak = StreakState(
      currentDays: try row.decode(Int.self, forColumn: "current_days"), longestDays: try row.decode(Int.self, forColumn: "longest_days"),
      shields: try row.decode(Int.self, forColumn: "shields"), completionsTowardShield: try row.decode(Int.self, forColumn: "toward_shield"),
      pendingShieldGrant: try row.decode(Int.self, forColumn: "pending_shields"))
    runStartDate = try DerivedColumn.date(row, "run_start")
    lastCountedDate = try DerivedColumn.date(row, "last_counted")
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["quest"] = id
    container["created_order"] = createdOrder
    container["created_on"] = createdOn.isoString
    container["schedule"] = String(decoding: try MemoirReconciler.canonicalJSON(schedule), as: UTF8.self)
    container["current_days"] = streak.currentDays
    container["longest_days"] = streak.longestDays
    container["shields"] = streak.shields
    container["toward_shield"] = streak.completionsTowardShield
    container["pending_shields"] = streak.pendingShieldGrant
    container["run_start"] = runStartDate?.isoString
    container["last_counted"] = lastCountedDate?.isoString
  }
}

/// One occurrence's reschedule, kept even after the log it marked yields to an outcome, as the reschedule cap counts it.
public struct RescheduleRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_reschedule"
  static let definition = """
    CREATE TABLE mm_derived_reschedule (
      date TEXT NOT NULL, quest BLOB NOT NULL, from_minute INTEGER, to_minute INTEGER NOT NULL, reason_tag TEXT, reason_note BLOB, PRIMARY KEY (date, quest)
    ) STRICT, WITHOUT ROWID
    """

  public let occurrence: Occurrence
  public let entry: RescheduleEntry

  init(occurrence: Occurrence, entry: RescheduleEntry) {
    self.occurrence = occurrence
    self.entry = entry
  }

  public init(row: Row) throws {
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a reschedule row has no date") }
    occurrence = Occurrence(quest: try row.decode(UUID.self, forColumn: "quest"), date: date)
    entry = RescheduleEntry(
      fromMinute: try row.decode(Int?.self, forColumn: "from_minute"), toMinute: try row.decode(Int.self, forColumn: "to_minute"),
      reasonTag: try DerivedColumn.token(row, "reason_tag"), reasonNote: try row.decode(UUID?.self, forColumn: "reason_note"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = occurrence.date.isoString
    container["quest"] = occurrence.quest
    container["from_minute"] = entry.fromMinute
    container["to_minute"] = entry.toMinute
    container["reason_tag"] = entry.reasonTag?.rawValue
    container["reason_note"] = entry.reasonNote
  }
}

/// A day's Recovery quest.
public struct RecoveryRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_recovery"
  static let definition = """
    CREATE TABLE mm_derived_recovery (
      date TEXT PRIMARY KEY, id BLOB NOT NULL, source_quest BLOB, trigger_logs TEXT, returner_day INTEGER NOT NULL, state TEXT NOT NULL, reflection BLOB,
      completed_at_millis INTEGER, expires_at_millis INTEGER
    ) STRICT, WITHOUT ROWID
    """

  public let recovery: RecoveryQuest

  init(_ recovery: RecoveryQuest) {
    self.recovery = recovery
  }

  public init(row: Row) throws {
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a recovery row has no date") }
    recovery = RecoveryQuest(
      id: try row.decode(UUID.self, forColumn: "id"), date: date, sourceQuest: try row.decode(UUID?.self, forColumn: "source_quest"),
      triggerLogs: try DerivedColumn.identifiers(row, "trigger_logs"), isReturnerDay: try row.decode(Bool.self, forColumn: "returner_day"),
      state: try DerivedColumn.required(row, "state"), reflection: try row.decode(UUID?.self, forColumn: "reflection"),
      completedAtMillis: try row.decode(Int64?.self, forColumn: "completed_at_millis"), expiresAtMillis: try row.decode(Int64?.self, forColumn: "expires_at_millis"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = recovery.date.isoString
    container["id"] = recovery.id
    container["source_quest"] = recovery.sourceQuest
    container["trigger_logs"] = try DerivedColumn.identifiersText(recovery.triggerLogs)
    container["returner_day"] = recovery.isReturnerDay
    container["state"] = recovery.state.rawValue
    container["reflection"] = recovery.reflection
    container["completed_at_millis"] = recovery.completedAtMillis
    container["expires_at_millis"] = recovery.expiresAtMillis
  }
}

/// A day the Returner ritual fired.
public struct ReturnerRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_returner"
  static let definition = """
    CREATE TABLE mm_derived_returner (
      date TEXT PRIMARY KEY, last_active TEXT NOT NULL, days_absent INTEGER NOT NULL, shield_target BLOB, shield_pending INTEGER NOT NULL,
      intensity_mode TEXT NOT NULL
    ) STRICT, WITHOUT ROWID
    """

  public let event: ReturnerEvent

  init(_ event: ReturnerEvent) {
    self.event = event
  }

  public init(row: Row) throws {
    guard let date = try DerivedColumn.date(row, "date"), let lastActive = try DerivedColumn.date(row, "last_active") else {
      throw StoreError.corruptStore("a returner row has no date")
    }
    event = ReturnerEvent(
      date: date, lastActiveDate: lastActive, daysAbsent: try row.decode(Int.self, forColumn: "days_absent"),
      shieldTarget: try row.decode(UUID?.self, forColumn: "shield_target"), shieldPending: try row.decode(Bool.self, forColumn: "shield_pending"),
      intensityMode: try DerivedColumn.required(row, "intensity_mode"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = event.date.isoString
    container["last_active"] = event.lastActiveDate.isoString
    container["days_absent"] = event.daysAbsent
    container["shield_target"] = event.shieldTarget
    container["shield_pending"] = event.shieldPending
    container["intensity_mode"] = event.intensityMode.rawValue
  }
}

/// One entry of the hero trail, at its place in it; screens list only the latest visible ones (`MemoirDerived.recentHeroEvents`).
public struct HeroEventRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_hero_event"
  /// `HIDDEN_EVENT_TYPES` (`lib/sync/synced-hero-provider.ts:61`): a Crown period opening is never listed, so it never takes a place in the view; nor is
  /// the daily money log, one a covered day, which would crowd out everything else.
  public static let hiddenTypes: Set<HeroEventType> = [.crownInit, .moneyLog]
  static let definition = """
    CREATE TABLE mm_derived_hero_event (
      ordinal INTEGER PRIMARY KEY, key TEXT NOT NULL, type TEXT NOT NULL, date TEXT NOT NULL, xp INTEGER NOT NULL, coins INTEGER NOT NULL, stat TEXT,
      stat_delta INTEGER NOT NULL, quest BLOB, log BLOB, state TEXT, achievement TEXT, level_after INTEGER NOT NULL, ruleset_version INTEGER NOT NULL
    ) STRICT
    """

  public let ordinal: Int
  public let event: HeroEvent

  init(ordinal: Int, event: HeroEvent) {
    self.ordinal = ordinal
    self.event = event
  }

  public init(row: Row) throws {
    ordinal = try row.decode(Int.self, forColumn: "ordinal")
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a hero event row has no date") }
    event = HeroEvent(
      key: try row.decode(String.self, forColumn: "key"), type: try DerivedColumn.required(row, "type"), date: date, xpDelta: try row.decode(Int.self, forColumn: "xp"),
      coinsDelta: try row.decode(Int.self, forColumn: "coins"), statAffinity: try DerivedColumn.token(row, "stat"),
      statDelta: try row.decode(Int.self, forColumn: "stat_delta"), quest: try row.decode(UUID?.self, forColumn: "quest"), log: try row.decode(UUID?.self, forColumn: "log"),
      state: try DerivedColumn.token(row, "state"), achievement: try DerivedColumn.token(row, "achievement"), levelAfter: try row.decode(Int.self, forColumn: "level_after"),
      rulesetVersion: try row.decode(Int.self, forColumn: "ruleset_version"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["ordinal"] = ordinal
    container["key"] = event.key
    container["type"] = event.type.rawValue
    container["date"] = event.date.isoString
    container["xp"] = event.xpDelta
    container["coins"] = event.coinsDelta
    container["stat"] = event.statAffinity?.rawValue
    container["stat_delta"] = event.statDelta
    container["quest"] = event.quest
    container["log"] = event.log
    container["state"] = event.state?.rawValue
    container["achievement"] = event.achievement?.rawValue
    container["level_after"] = event.levelAfter
    container["ruleset_version"] = event.rulesetVersion
  }
}

/// What one quest's logs in one state add up to.
public struct QuestLogTally: Hashable, Sendable {
  public let quest: UUID
  public let state: QuestLogState
  public let count: Int
  public let xp: Int
  public let coins: Int
}

extension MemoirDerived {
  public static func quests(in transaction: ReadTransaction) throws(StoreError) -> [QuestRow] {
    try fetch(QuestRow.self, in: transaction) { database in try QuestRow.order(Column("created_order")).fetchAll(database) } ?? []
  }

  public static func quest(_ id: UUID, in transaction: ReadTransaction) throws(StoreError) -> QuestRow? {
    try fetch(QuestRow.self, in: transaction) { database in try QuestRow.filter(Column("quest") == id).fetchOne(database) } ?? nil
  }

  public static func questLogs(from start: LocalDate, through end: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> [QuestLogRow] {
    try fetch(QuestLogRow.self, in: transaction) { database in
      try QuestLogRow.filter(Column("date") >= start.isoString && Column("date") <= end.isoString).order(Column("date"), Column("quest")).fetchAll(database)
    } ?? []
  }

  /// The quest's logs on or before `end`, latest first; `limit` nil reads them all.
  public static func questLogs(of quest: UUID, through end: LocalDate, limit: Int?, in transaction: ReadTransaction) throws(StoreError) -> [QuestLogRow] {
    try fetch(QuestLogRow.self, in: transaction) { database in
      let request = QuestLogRow.filter(Column("quest") == quest && Column("date") <= end.isoString).order(Column("date").desc)
      return try (limit.map { request.limit(max(0, $0)) } ?? request).fetchAll(database)
    } ?? []
  }

  public static func earliestQuestLogDate(in transaction: ReadTransaction) throws(StoreError) -> LocalDate? {
    try fetch(QuestLogRow.self, in: transaction) { database in
      try String.fetchOne(database, sql: "SELECT MIN(date) FROM \(QuestLogRow.databaseTableName)").flatMap(LocalDate.init(isoString:))
    } ?? nil
  }

  /// Every quest's logs grouped by state.
  public static func questLogTallies(in transaction: ReadTransaction) throws(StoreError) -> [QuestLogTally] {
    try fetch(QuestLogRow.self, in: transaction) { database in
      try Row.fetchAll(
        database, sql: "SELECT quest, state, COUNT(*) AS count, SUM(xp) AS xp, SUM(coins) AS coins FROM \(QuestLogRow.databaseTableName) GROUP BY quest, state"
      ).map { row in
        QuestLogTally(
          quest: try row.decode(UUID.self, forColumn: "quest"), state: try DerivedColumn.required(row, "state"), count: try row.decode(Int.self, forColumn: "count"),
          xp: try row.decode(Int.self, forColumn: "xp"), coins: try row.decode(Int.self, forColumn: "coins"))
      }
    } ?? []
  }

  public static func reschedules(from start: LocalDate, through end: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> [RescheduleRow] {
    try fetch(RescheduleRow.self, in: transaction) { database in
      try RescheduleRow.filter(Column("date") >= start.isoString && Column("date") <= end.isoString).order(Column("date")).fetchAll(database)
    } ?? []
  }

  public static func recoveries(from start: LocalDate, through end: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> [RecoveryRow] {
    try fetch(RecoveryRow.self, in: transaction) { database in
      try RecoveryRow.filter(Column("date") >= start.isoString && Column("date") <= end.isoString).order(Column("date")).fetchAll(database)
    } ?? []
  }

  public static func returners(from start: LocalDate, through end: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> [ReturnerRow] {
    try fetch(ReturnerRow.self, in: transaction) { database in
      try ReturnerRow.filter(Column("date") >= start.isoString && Column("date") <= end.isoString).order(Column("date")).fetchAll(database)
    } ?? []
  }

  /// The latest hero trail entries a screen lists, hidden kinds left out, latest first.
  public static func recentHeroEvents(limit: Int = recentHeroEventLimit, in transaction: ReadTransaction) throws(StoreError) -> [HeroEventRow] {
    try fetch(HeroEventRow.self, in: transaction) { database in
      try HeroEventRow.filter(!HeroEventRow.hiddenTypes.map(\.rawValue).contains(Column("type"))).order(Column("ordinal").desc).limit(max(0, limit)).fetchAll(database)
    } ?? []
  }

  public static let recentHeroEventLimit = 32

  /// The whole hero trail, hidden kinds included, in the order replay granted it.
  public static func heroEvents(in transaction: ReadTransaction) throws(StoreError) -> [HeroEventRow] {
    try fetch(HeroEventRow.self, in: transaction) { database in try HeroEventRow.order(Column("ordinal")).fetchAll(database) } ?? []
  }

  /// The days a Crown period closed on, latest first.
  public static func crownCloses(limit: Int, in transaction: ReadTransaction) throws(StoreError) -> [DayRow] {
    try fetch(DayRow.self, in: transaction) { database in
      try DayRow.filter(Column("crown_banked_xp") != nil).order(Column("date").desc).limit(max(0, limit)).fetchAll(database)
    } ?? []
  }
}
