import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// The hero as the view shows it: totals, the displayed title, the open day and, when replay halted on a command this build cannot read, why.
public struct HeroSummaryRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_hero"
  static let definition = """
    CREATE TABLE mm_derived_hero (
      slot INTEGER PRIMARY KEY CHECK (slot = 1), total_xp INTEGER NOT NULL, level INTEGER NOT NULL, coins INTEGER NOT NULL, discipline INTEGER NOT NULL,
      body INTEGER NOT NULL, wealth INTEGER NOT NULL, mind INTEGER NOT NULL, displayed_title TEXT, open_day TEXT, commands INTEGER NOT NULL, halt TEXT
    ) STRICT
    """

  public let totalXP: Int
  public let level: Int
  public let coins: Int
  public let stats: RuleTable<StatAffinity, Int>
  public let displayedTitle: TitleID?
  public let openDay: LocalDate?
  public let commandCount: Int
  /// Set when replay stopped at a command this build cannot read: the app needs an update before the hero moves again.
  public let halt: ReplayHalt?

  public var needsAppUpdate: Bool { halt != nil }

  init(_ state: ReplayState) {
    totalXP = state.hero.totalXP
    level = state.hero.level
    coins = state.hero.coins
    stats = state.hero.stats
    displayedTitle = state.progression.displayedTitle
    openDay = state.openDay
    commandCount = state.commandCount
    halt = state.halt
  }

  public init(row: Row) throws {
    totalXP = try row.decode(Int.self, forColumn: "total_xp")
    level = try row.decode(Int.self, forColumn: "level")
    coins = try row.decode(Int.self, forColumn: "coins")
    let discipline = try row.decode(Int.self, forColumn: "discipline")
    let body = try row.decode(Int.self, forColumn: "body")
    let wealth = try row.decode(Int.self, forColumn: "wealth")
    let mind = try row.decode(Int.self, forColumn: "mind")
    stats = RuleTable { stat in
      switch stat {
      case .discipline: discipline
      case .body: body
      case .wealth: wealth
      case .mind: mind
      }
    }
    displayedTitle = try DerivedColumn.token(row, "displayed_title")
    openDay = try DerivedColumn.date(row, "open_day")
    commandCount = try row.decode(Int.self, forColumn: "commands")
    halt = try row.decode(String?.self, forColumn: "halt").map { text in
      guard let halt = try? JSONDecoder().decode(ReplayHalt.self, from: Data(text.utf8)) else { throw StoreError.corruptStore("the hero row holds an unreadable halt") }
      return halt
    }
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["slot"] = 1
    container["total_xp"] = totalXP
    container["level"] = level
    container["coins"] = coins
    container["discipline"] = stats[.discipline]
    container["body"] = stats[.body]
    container["wealth"] = stats[.wealth]
    container["mind"] = stats[.mind]
    container["displayed_title"] = displayedTitle?.rawValue
    container["open_day"] = openDay?.isoString
    container["commands"] = commandCount
    container["halt"] = try halt.map { halt in String(decoding: try MemoirReconciler.canonicalJSON(halt), as: UTF8.self) }
  }
}

/// One occurrence's log, keyed by date and quest.
public struct QuestLogRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_quest_log"
  static let definition = """
    CREATE TABLE mm_derived_quest_log (
      date TEXT NOT NULL, quest BLOB NOT NULL, id BLOB NOT NULL, state TEXT NOT NULL, xp INTEGER NOT NULL, coins INTEGER NOT NULL, stat TEXT NOT NULL,
      strictness TEXT NOT NULL, intensity_mode TEXT NOT NULL, crown_slice_halves INTEGER NOT NULL, ruleset_version INTEGER NOT NULL, reason_tag TEXT,
      reason_note BLOB, reflection BLOB, rescheduled_to_minute INTEGER, postponed_to TEXT, performed_at_millis INTEGER, created_at_millis INTEGER NOT NULL,
      PRIMARY KEY (date, quest)
    ) STRICT, WITHOUT ROWID
    """

  public let occurrence: Occurrence
  public let entry: QuestLogEntry

  init(occurrence: Occurrence, entry: QuestLogEntry) {
    self.occurrence = occurrence
    self.entry = entry
  }

  public init(row: Row) throws {
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a quest log row has no date") }
    occurrence = Occurrence(quest: try row.decode(UUID.self, forColumn: "quest"), date: date)
    entry = QuestLogEntry(
      id: try row.decode(UUID.self, forColumn: "id"), state: try DerivedColumn.required(row, "state"), xpAwarded: try row.decode(Int.self, forColumn: "xp"),
      coinsAwarded: try row.decode(Int.self, forColumn: "coins"), statAffinity: try DerivedColumn.required(row, "stat"),
      strictness: try DerivedColumn.required(row, "strictness"), intensityModeAtLog: try DerivedColumn.required(row, "intensity_mode"),
      crownSliceWeight: Halves(try row.decode(Int.self, forColumn: "crown_slice_halves")), rulesetVersion: try row.decode(Int.self, forColumn: "ruleset_version"),
      reasonTag: try DerivedColumn.token(row, "reason_tag"), reasonNote: try row.decode(UUID?.self, forColumn: "reason_note"),
      reflection: try row.decode(UUID?.self, forColumn: "reflection"), rescheduledToMinute: try row.decode(Int?.self, forColumn: "rescheduled_to_minute"),
      postponedToDate: try DerivedColumn.date(row, "postponed_to"), performedAtMillis: try row.decode(Int64?.self, forColumn: "performed_at_millis"),
      createdAtMillis: try row.decode(Int64.self, forColumn: "created_at_millis"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = occurrence.date.isoString
    container["quest"] = occurrence.quest
    container["id"] = entry.id
    container["state"] = entry.state.rawValue
    container["xp"] = entry.xpAwarded
    container["coins"] = entry.coinsAwarded
    container["stat"] = entry.statAffinity.rawValue
    container["strictness"] = entry.strictness.rawValue
    container["intensity_mode"] = entry.intensityModeAtLog.rawValue
    container["crown_slice_halves"] = entry.crownSliceWeight.halves
    container["ruleset_version"] = entry.rulesetVersion
    container["reason_tag"] = entry.reasonTag?.rawValue
    container["reason_note"] = entry.reasonNote
    container["reflection"] = entry.reflection
    container["rescheduled_to_minute"] = entry.rescheduledToMinute
    container["postponed_to"] = entry.postponedToDate?.isoString
    container["performed_at_millis"] = entry.performedAtMillis
    container["created_at_millis"] = entry.createdAtMillis
  }
}

public enum DayLockState: String, Sendable, Hashable {
  case none
  case active
  case broken
}

/// One day as the walk left it: open or closed, its HP and Crown, its lock, Comeback and Returner, and its Recovery quest.
public struct DayRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_day"
  static let definition = """
    CREATE TABLE mm_derived_day (
      date TEXT PRIMARY KEY, closed INTEGER NOT NULL, intensity_mode TEXT NOT NULL, ruleset_version INTEGER NOT NULL, hp_start INTEGER, hp_end INTEGER,
      hp_max INTEGER, hp_spent INTEGER, crown_period_start TEXT, crown_endowed_halves INTEGER, crown_forfeited_halves INTEGER, crown_remaining_xp INTEGER,
      crown_remaining_coins INTEGER, crown_banked_xp INTEGER, crown_banked_coins INTEGER, lock TEXT NOT NULL, momentum TEXT NOT NULL,
      missed INTEGER NOT NULL, comeback_armed INTEGER NOT NULL, comeback_fires INTEGER NOT NULL, returner_fired INTEGER NOT NULL, recovery TEXT
    ) STRICT, WITHOUT ROWID
    """

  public let date: LocalDate
  public let isClosed: Bool
  public let intensityMode: IntensityMode
  public let rulesetVersion: Int
  public let hp: DayHP?
  public let crownPeriodStart: LocalDate?
  public let crownEndowed: Halves?
  public let crownForfeited: Halves?
  public let crownRemaining: RewardAmount?
  public let crownBanked: RewardAmount?
  public let lock: DayLockState
  public let momentum: MomentumBucket
  public let missedCount: Int
  public let comebackArmed: Bool
  public let comebackFires: Int
  public let returnerFired: Bool
  public let recovery: RecoveryQuestState?

  init(_ day: ReplayDay, recovery: RecoveryQuest?) {
    date = day.date
    isClosed = day.isClosed
    intensityMode = day.intensityMode
    rulesetVersion = day.rulesetVersion
    hp = day.hp
    crownPeriodStart = day.crown?.periodStart
    crownEndowed = day.crown?.state.endowedWeight
    crownForfeited = day.crown?.state.forfeitedWeight
    crownRemaining = day.crown.map { RewardAmount(xp: $0.state.remainingXP, coins: $0.state.remainingCoins) }
    crownBanked = day.crown?.banked
    lock = day.lock.map { $0.isActive ? .active : .broken } ?? DayLockState.none
    momentum = day.momentum
    missedCount = day.missedCount
    comebackArmed = day.comeback.armed
    comebackFires = day.comeback.fires
    returnerFired = day.returnerFired
    self.recovery = recovery?.state
  }

  public init(row: Row) throws {
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a day row has no date") }
    self.date = date
    isClosed = try row.decode(Bool.self, forColumn: "closed")
    intensityMode = try DerivedColumn.required(row, "intensity_mode")
    rulesetVersion = try row.decode(Int.self, forColumn: "ruleset_version")
    let hpStart = try row.decode(Int?.self, forColumn: "hp_start")
    let hpEnd = try row.decode(Int?.self, forColumn: "hp_end")
    let hpMax = try row.decode(Int?.self, forColumn: "hp_max")
    let hpSpent = try row.decode(Int?.self, forColumn: "hp_spent")
    if let hpStart, let hpEnd, let hpMax, let hpSpent { hp = DayHP(hpStart: hpStart, hpEnd: hpEnd, hpMax: hpMax, spent: hpSpent) } else { hp = nil }
    crownPeriodStart = try DerivedColumn.date(row, "crown_period_start")
    crownEndowed = try row.decode(Int?.self, forColumn: "crown_endowed_halves").map(Halves.init)
    crownForfeited = try row.decode(Int?.self, forColumn: "crown_forfeited_halves").map(Halves.init)
    crownRemaining = try DerivedColumn.amount(row, xp: "crown_remaining_xp", coins: "crown_remaining_coins")
    crownBanked = try DerivedColumn.amount(row, xp: "crown_banked_xp", coins: "crown_banked_coins")
    lock = try DerivedColumn.required(row, "lock")
    momentum = try DerivedColumn.required(row, "momentum")
    missedCount = try row.decode(Int.self, forColumn: "missed")
    comebackArmed = try row.decode(Bool.self, forColumn: "comeback_armed")
    comebackFires = try row.decode(Int.self, forColumn: "comeback_fires")
    returnerFired = try row.decode(Bool.self, forColumn: "returner_fired")
    recovery = try DerivedColumn.token(row, "recovery")
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = date.isoString
    container["closed"] = isClosed
    container["intensity_mode"] = intensityMode.rawValue
    container["ruleset_version"] = rulesetVersion
    container["hp_start"] = hp?.hpStart
    container["hp_end"] = hp?.hpEnd
    container["hp_max"] = hp?.hpMax
    container["hp_spent"] = hp?.spent
    container["crown_period_start"] = crownPeriodStart?.isoString
    container["crown_endowed_halves"] = crownEndowed?.halves
    container["crown_forfeited_halves"] = crownForfeited?.halves
    container["crown_remaining_xp"] = crownRemaining?.xp
    container["crown_remaining_coins"] = crownRemaining?.coins
    container["crown_banked_xp"] = crownBanked?.xp
    container["crown_banked_coins"] = crownBanked?.coins
    container["lock"] = lock.rawValue
    container["momentum"] = momentum.rawValue
    container["missed"] = missedCount
    container["comeback_armed"] = comebackArmed
    container["comeback_fires"] = comebackFires
    container["returner_fired"] = returnerFired
    container["recovery"] = recovery?.rawValue
  }
}

public enum UnlockKind: String, Sendable, Hashable, CaseIterable {
  case achievement
  case title
  case cosmetic
}

/// An earned achievement or title, or an owned cosmetic.
public struct UnlockRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_unlock"
  static let definition = """
    CREATE TABLE mm_derived_unlock (
      kind TEXT NOT NULL, id TEXT NOT NULL, unlocked_on TEXT, source TEXT, equipped INTEGER NOT NULL, PRIMARY KEY (kind, id)
    ) STRICT, WITHOUT ROWID
    """

  public let kind: UnlockKind
  public let id: String
  /// Nil for a cosmetic, whose day the reference does not keep.
  public let unlockedOn: LocalDate?
  public let source: CosmeticSource?
  public let equipped: Bool

  init(kind: UnlockKind, id: String, unlockedOn: LocalDate?, source: CosmeticSource? = nil, equipped: Bool = false) {
    self.kind = kind
    self.id = id
    self.unlockedOn = unlockedOn
    self.source = source
    self.equipped = equipped
  }

  public init(row: Row) throws {
    kind = try DerivedColumn.required(row, "kind")
    id = try row.decode(String.self, forColumn: "id")
    unlockedOn = try DerivedColumn.date(row, "unlocked_on")
    source = try DerivedColumn.token(row, "source")
    equipped = try row.decode(Bool.self, forColumn: "equipped")
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["kind"] = kind.rawValue
    container["id"] = id
    container["unlocked_on"] = unlockedOn?.isoString
    container["source"] = source?.rawValue
    container["equipped"] = equipped
  }
}

/// Something to tell the owner once, in the order replay raised it.
public struct NoticeRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_notice"
  static let definition = """
    CREATE TABLE mm_derived_notice (
      ordinal INTEGER PRIMARY KEY, kind TEXT NOT NULL, command BLOB NOT NULL, cosmetic TEXT NOT NULL, balance INTEGER NOT NULL, price INTEGER NOT NULL
    ) STRICT
    """

  public let ordinal: Int
  public let notice: ReplayNotice

  init(ordinal: Int, notice: ReplayNotice) {
    self.ordinal = ordinal
    self.notice = notice
  }

  public init(row: Row) throws {
    ordinal = try row.decode(Int.self, forColumn: "ordinal")
    guard try row.decode(String.self, forColumn: "kind") == "purchase_withdrawn" else { throw StoreError.corruptStore("a notice row holds an unknown kind") }
    notice = .purchaseWithdrawn(
      command: try row.decode(UUID.self, forColumn: "command"), cosmetic: try DerivedColumn.required(row, "cosmetic"),
      balance: try row.decode(Int.self, forColumn: "balance"), price: try row.decode(Int.self, forColumn: "price"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["ordinal"] = ordinal
    switch notice {
    case .purchaseWithdrawn(let command, let cosmetic, let balance, let price):
      container["kind"] = "purchase_withdrawn"
      container["command"] = command
      container["cosmetic"] = cosmetic.rawValue
      container["balance"] = balance
      container["price"] = price
    }
  }
}

/// The derived rows of one replay state, table by table.
struct DerivedRows: Equatable {
  let hero: Set<HeroSummaryRow>
  let questLogs: Set<QuestLogRow>
  let days: Set<DayRow>
  let unlocks: Set<UnlockRow>
  let notices: Set<NoticeRow>

  init(hero: Set<HeroSummaryRow>, questLogs: Set<QuestLogRow>, days: Set<DayRow>, unlocks: Set<UnlockRow>, notices: Set<NoticeRow>) {
    self.hero = hero
    self.questLogs = questLogs
    self.days = days
    self.unlocks = unlocks
    self.notices = notices
  }

  init(_ state: ReplayState) {
    hero = [HeroSummaryRow(state)]
    questLogs = Set(state.logs.all.map { QuestLogRow(occurrence: $0.occurrence, entry: $0.value) })
    days = Set(state.days.values.map { DayRow($0, recovery: state.compassion.recoveries[$0.date]) })
    let progression = state.progression
    unlocks = Set(
      progression.achievements.map { UnlockRow(kind: .achievement, id: $0.key.rawValue, unlockedOn: $0.value) }
        + progression.titles.map { UnlockRow(kind: .title, id: $0.key.rawValue, unlockedOn: $0.value) }
        + progression.cosmetics.map { UnlockRow(kind: .cosmetic, id: $0.key.rawValue, unlockedOn: nil, source: $0.value.source, equipped: $0.value.equipped) })
    notices = Set(state.notices.enumerated().map { NoticeRow(ordinal: $0.offset, notice: $0.element) })
  }

  static let definitions = [HeroSummaryRow.definition, QuestLogRow.definition, DayRow.definition, UnlockRow.definition, NoticeRow.definition]
  static let tables = [
    HeroSummaryRow.databaseTableName, QuestLogRow.databaseTableName, DayRow.databaseTableName, UnlockRow.databaseTableName, NoticeRow.databaseTableName,
  ]

  static func stored(in database: Database) throws -> DerivedRows {
    DerivedRows(
      hero: Set(try HeroSummaryRow.fetchAll(database)), questLogs: Set(try QuestLogRow.fetchAll(database)), days: Set(try DayRow.fetchAll(database)),
      unlocks: Set(try UnlockRow.fetchAll(database)), notices: Set(try NoticeRow.fetchAll(database)))
  }

  /// Rewrites only the rows that differ from what the tables hold.
  func write(in database: Database) throws {
    let stored = try Self.stored(in: database)
    try Self.replace(stored.hero, with: hero, in: database)
    try Self.replace(stored.questLogs, with: questLogs, in: database)
    try Self.replace(stored.days, with: days, in: database)
    try Self.replace(stored.unlocks, with: unlocks, in: database)
    try Self.replace(stored.notices, with: notices, in: database)
  }

  private static func replace<Output: PersistableRecord & Hashable>(_ stored: Set<Output>, with rows: Set<Output>, in database: Database) throws {
    for row in stored.subtracting(rows) { try row.delete(database) }
    for row in rows.subtracting(stored) { try row.insert(database) }
  }
}

/// Reads of the derived tables, which exist once the projection has run; before that every read is empty.
public enum MemoirDerived {
  public static func hero(in transaction: ReadTransaction) throws(StoreError) -> HeroSummaryRow? {
    try fetch(HeroSummaryRow.self, in: transaction) { try HeroSummaryRow.fetchOne($0) }
  }

  public static func days(from start: LocalDate, through end: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> [DayRow] {
    try fetch(DayRow.self, in: transaction) { database in
      try DayRow.filter(Column("date") >= start.isoString && Column("date") <= end.isoString).order(Column("date")).fetchAll(database)
    } ?? []
  }

  public static func questLogs(on date: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> [QuestLogRow] {
    try fetch(QuestLogRow.self, in: transaction) { database in try QuestLogRow.filter(Column("date") == date.isoString).fetchAll(database) } ?? []
  }

  public static func unlocks(in transaction: ReadTransaction) throws(StoreError) -> [UnlockRow] {
    try fetch(UnlockRow.self, in: transaction) { database in try UnlockRow.order(Column("kind"), Column("id")).fetchAll(database) } ?? []
  }

  public static func notices(in transaction: ReadTransaction) throws(StoreError) -> [NoticeRow] {
    try fetch(NoticeRow.self, in: transaction) { database in try NoticeRow.order(Column("ordinal")).fetchAll(database) } ?? []
  }

  private static func fetch<Output: TableRecord, T>(_: Output.Type, in transaction: ReadTransaction, _ body: (Database) throws -> T?) throws(StoreError) -> T? {
    try MemoirProjectionSQL.run {
      guard try transaction.database.tableExists(Output.databaseTableName) else { return nil }
      return try body(transaction.database)
    }
  }
}

enum DerivedColumn {
  static func date(_ row: Row, _ column: String) throws -> LocalDate? {
    guard let text = try row.decode(String?.self, forColumn: column) else { return nil }
    guard let date = LocalDate(isoString: text) else { throw StoreError.corruptStore("\(column) holds \(text), which is not a date") }
    return date
  }

  static func token<Token: RawRepresentable<String>>(_ row: Row, _ column: String) throws -> Token? {
    guard let text = try row.decode(String?.self, forColumn: column) else { return nil }
    guard let token = Token(rawValue: text) else { throw StoreError.corruptStore("\(column) holds an unknown value") }
    return token
  }

  static func required<Token: RawRepresentable<String>>(_ row: Row, _ column: String) throws -> Token {
    guard let token: Token = try token(row, column) else { throw StoreError.corruptStore("\(column) is empty") }
    return token
  }

  static func amount(_ row: Row, xp: String, coins: String) throws -> RewardAmount? {
    guard let xp = try row.decode(Int?.self, forColumn: xp), let coins = try row.decode(Int?.self, forColumn: coins) else { return nil }
    return RewardAmount(xp: xp, coins: coins)
  }
}

enum MemoirProjectionSQL {
  static func run<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch let error as StoreError {
      throw error
    } catch let error as DatabaseError {
      throw .database("SQLite error \(error.extendedResultCode.rawValue): \(error.message ?? "no message")")
    } catch {
      throw .aborted(error)
    }
  }
}
