import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// Money in the game as replay left it: the weekly money streak, the saving streak, the latest money activity, and the debuff in force on the open day.
public struct MoneyRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_money"
  static let definition = """
    CREATE TABLE mm_derived_money (
      slot INTEGER PRIMARY KEY CHECK (slot = 1), week_streak INTEGER NOT NULL, last_settled_week TEXT, saving_streak INTEGER NOT NULL,
      last_activity_day TEXT, debuff_multiplier INTEGER, debuff_through TEXT, CHECK ((debuff_multiplier IS NULL) = (debuff_through IS NULL))
    ) STRICT
    """

  public let weekStreak: Int
  /// The start of the latest week the walk settled; the week after it is the one being counted.
  public let lastSettledWeekStart: LocalDate?
  public let savingStreak: Int
  public let lastActivityDay: LocalDate?
  /// The XP multiplier in force on the open day, and the latest last day of the debuffs covering it; nil without one.
  public let debuff: Debuff?

  public struct Debuff: Hashable, Sendable {
    public let multiplier: Thousandths
    public let through: LocalDate
  }

  init(_ state: ReplayState) {
    let money = state.money
    weekStreak = money.weekStreak
    lastSettledWeekStart = money.lastSettledWeekStart
    savingStreak = money.savingStreak
    lastActivityDay = money.lastActivityDay
    debuff = state.openDay.flatMap { day in
      guard let multiplier = money.debuffMultiplier(on: day), let through = money.debuffEnd(on: day) else { return nil }
      return Debuff(multiplier: multiplier, through: through)
    }
  }

  public init(row: Row) throws {
    weekStreak = try row.decode(Int.self, forColumn: "week_streak")
    lastSettledWeekStart = try DerivedColumn.date(row, "last_settled_week")
    savingStreak = try row.decode(Int.self, forColumn: "saving_streak")
    lastActivityDay = try DerivedColumn.date(row, "last_activity_day")
    switch (try row.decode(Int?.self, forColumn: "debuff_multiplier"), try DerivedColumn.date(row, "debuff_through")) {
    case (let multiplier?, let through?): debuff = Debuff(multiplier: Thousandths(multiplier), through: through)
    case (nil, nil): debuff = nil
    default: throw StoreError.corruptStore("the money row holds a debuff multiplier without its last day")
    }
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["slot"] = 1
    container["week_streak"] = weekStreak
    container["last_settled_week"] = lastSettledWeekStart?.isoString
    container["saving_streak"] = savingStreak
    container["last_activity_day"] = lastActivityDay?.isoString
    container["debuff_multiplier"] = debuff?.multiplier.thousandths
    container["debuff_through"] = debuff?.through.isoString
  }
}

/// A day whose money logging was covered, and the first command that covered it. This is the one source of a period's logging coverage.
public struct MoneyDayRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_money_day"
  static let definition = """
    CREATE TABLE mm_derived_money_day (date TEXT PRIMARY KEY, source TEXT NOT NULL, command BLOB NOT NULL) STRICT, WITHOUT ROWID
    """

  public let date: LocalDate
  public let source: MoneyLogSource
  public let command: UUID

  init(date: LocalDate, coverage: MoneyCoverage) {
    self.date = date
    source = coverage.source
    command = coverage.command
  }

  public init(row: Row) throws {
    guard let date = try DerivedColumn.date(row, "date") else { throw StoreError.corruptStore("a money day row has no date") }
    self.date = date
    source = try DerivedColumn.required(row, "source")
    command = try row.decode(UUID.self, forColumn: "command")
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = date.isoString
    container["source"] = source.rawValue
    container["command"] = command
  }
}

/// A budget period's close as replay kept it: the earliest `budget.closePeriod` for the period, its outcome and what it did to the hero.
public struct MoneyCloseRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_money_close"
  static let definition = """
    CREATE TABLE mm_derived_money_close (
      budget BLOB NOT NULL, period_start TEXT NOT NULL, command BLOB NOT NULL, outcome TEXT NOT NULL, deposited INTEGER NOT NULL, closed_on TEXT NOT NULL,
      reward_xp INTEGER, reward_coins INTEGER, fine INTEGER, fine_applied INTEGER, debuff_from TEXT, debuff_through TEXT, debuff_multiplier INTEGER,
      PRIMARY KEY (budget, period_start)
    ) STRICT, WITHOUT ROWID
    """

  public let key: MoneyCloseKey
  public let close: MoneyClose

  init(key: MoneyCloseKey, close: MoneyClose) {
    self.key = key
    self.close = close
  }

  public init(row: Row) throws {
    guard let periodStart = try DerivedColumn.date(row, "period_start"), let closedOn = try DerivedColumn.date(row, "closed_on") else {
      throw StoreError.corruptStore("a money close row has no period start or close day")
    }
    key = MoneyCloseKey(budget: try row.decode(UUID.self, forColumn: "budget"), periodStart: periodStart)
    let command = try row.decode(UUID.self, forColumn: "command")
    let result: MoneyCloseResult
    if let reward = try DerivedColumn.amount(row, xp: "reward_xp", coins: "reward_coins") {
      result = .rewarded(reward)
    } else if let fine = try row.decode(Int?.self, forColumn: "fine"), let applied = try row.decode(Int?.self, forColumn: "fine_applied"),
      let from = try DerivedColumn.date(row, "debuff_from"), let through = try DerivedColumn.date(row, "debuff_through"),
      let multiplier = try row.decode(Int?.self, forColumn: "debuff_multiplier")
    {
      result = .fined(intended: fine, applied: applied, debuff: MoneyDebuffSpan(from: from, through: through, multiplier: Thousandths(multiplier), command: command))
    } else {
      throw StoreError.corruptStore("a money close row is neither rewarded nor fined")
    }
    close = MoneyClose(
      command: command, outcome: try DerivedColumn.required(row, "outcome"), deposited: try row.decode(Bool.self, forColumn: "deposited"), closedOn: closedOn,
      result: result)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["budget"] = key.budget
    container["period_start"] = key.periodStart.isoString
    container["command"] = close.command
    container["outcome"] = close.outcome.rawValue
    container["deposited"] = close.deposited
    container["closed_on"] = close.closedOn.isoString
    switch close.result {
    case .rewarded(let reward):
      container["reward_xp"] = reward.xp
      container["reward_coins"] = reward.coins
    case .fined(let intended, let applied, let debuff):
      container["fine"] = intended
      container["fine_applied"] = applied
      container["debuff_from"] = debuff.from.isoString
      container["debuff_through"] = debuff.through.isoString
      container["debuff_multiplier"] = debuff.multiplier.thousandths
    }
  }
}

/// A goal reward replay gave: one of the milestones, or the purchase.
public enum GoalReward: Sendable, Hashable {
  case milestone(GoalMilestone)
  case bought

  static let boughtToken = "bought"

  var token: String {
    switch self {
    case .milestone(let milestone): milestone.rawValue
    case .bought: Self.boughtToken
    }
  }

  init?(token: String) {
    if token == Self.boughtToken {
      self = .bought
    } else if let milestone = GoalMilestone(rawValue: token) {
      self = .milestone(milestone)
    } else {
      return nil
    }
  }
}

/// A goal reward already given, so the closer never issues it again; a later command for it is superseded.
public struct GoalRewardRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "mm_derived_goal_reward"
  static let definition = """
    CREATE TABLE mm_derived_goal_reward (goal BLOB NOT NULL, reward TEXT NOT NULL, PRIMARY KEY (goal, reward)) STRICT, WITHOUT ROWID
    """

  public let goal: UUID
  public let reward: GoalReward

  init(goal: UUID, reward: GoalReward) {
    self.goal = goal
    self.reward = reward
  }

  public init(row: Row) throws {
    goal = try row.decode(UUID.self, forColumn: "goal")
    guard let reward = GoalReward(token: try row.decode(String.self, forColumn: "reward")) else { throw StoreError.corruptStore("a goal reward row holds an unknown reward") }
    self.reward = reward
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["goal"] = goal
    container["reward"] = reward.token
  }

  static func rows(_ money: MoneyState) -> Set<GoalRewardRow> {
    Set(money.milestones.map { GoalRewardRow(goal: $0.goal, reward: .milestone($0.milestone)) } + money.goalsBought.map { GoalRewardRow(goal: $0, reward: .bought) })
  }
}

extension MemoirDerived {
  public static func money(in transaction: ReadTransaction) throws(StoreError) -> MoneyRow? {
    try fetch(MoneyRow.self, in: transaction) { try MoneyRow.fetchOne($0) }
  }

  /// The covered days from `start` through `end`, by date.
  public static func coveredDays(from start: LocalDate, through end: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> [MoneyDayRow] {
    try fetch(MoneyDayRow.self, in: transaction) { database in
      try MoneyDayRow.filter(Column("date") >= start.isoString && Column("date") <= end.isoString).order(Column("date")).fetchAll(database)
    } ?? []
  }

  /// Every close, by budget and period start.
  public static func moneyCloses(in transaction: ReadTransaction) throws(StoreError) -> [MoneyCloseRow] {
    try fetch(MoneyCloseRow.self, in: transaction) { database in try MoneyCloseRow.order(Column("budget"), Column("period_start")).fetchAll(database) } ?? []
  }

  public static func moneyClose(_ key: MoneyCloseKey, in transaction: ReadTransaction) throws(StoreError) -> MoneyCloseRow? {
    try fetch(MoneyCloseRow.self, in: transaction) { database in
      try MoneyCloseRow.filter(Column("budget") == key.budget && Column("period_start") == key.periodStart.isoString).fetchOne(database)
    } ?? nil
  }

  /// The rewards a goal has been given, milestones in order and then the purchase.
  public static func goalRewards(of goal: UUID, in transaction: ReadTransaction) throws(StoreError) -> [GoalRewardRow] {
    let rows = try fetch(GoalRewardRow.self, in: transaction) { database in try GoalRewardRow.filter(Column("goal") == goal).fetchAll(database) } ?? []
    return rows.sorted { $0.reward.order < $1.reward.order }
  }
}

extension GoalReward {
  fileprivate var order: Int {
    switch self {
    case .milestone(let milestone): GoalMilestone.allCases.firstIndex(of: milestone) ?? 0
    case .bought: GoalMilestone.allCases.count
    }
  }
}
