import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// What the read models take from the replay projection and the command log.
enum ReadSources {
  static func questLogs(in span: DateSpan, in transaction: ReadTransaction) throws(StoreError) -> [QuestLogRow] {
    try MemoirDerived.questLogs(from: span.start, through: span.end, in: transaction)
  }

  static func allQuestLogs(in transaction: ReadTransaction) throws(StoreError) -> [QuestLogRow] {
    try MemoirDerived.questLogs(from: .earliest, through: .latest, in: transaction)
  }

  /// Quest names from the main store, by id; a quest whose record is missing or unreadable has no name.
  static func questNames(in transaction: ReadTransaction) throws(StoreError) -> [UUID: String] {
    var names = [UUID: String]()
    for entry in try QuestRecord.listing(in: transaction).entries { names[entry.record.id] = entry.record.name }
    return names
  }

  /// Every command whose body decodes, in clock order, and how many this version cannot read (an unreadable item or a newer device's type).
  static func commands(in transaction: ReadTransaction) throws(StoreError) -> (commands: [(command: MemoirCommand, body: MemoirCommandBody)], unreadable: Int) {
    let listing = try MemoirCommand.listing(in: transaction)
    var commands = [(command: MemoirCommand, body: MemoirCommandBody)]()
    var unreadable = listing.unreadable
    for entry in listing.entries {
      do throws(CommandRefusal) {
        commands.append((entry.record, try MemoirCommandBody(entry.record)))
      } catch {
        unreadable += 1
      }
    }
    return (commands, unreadable)
  }

  static func listing<Record: MemoirRecord>(_: Record.Type, in transaction: ReadTransaction) throws(StoreError) -> (records: [Record], unreadable: Int) {
    let listing = try Record.listing(in: transaction)
    return (listing.entries.filter { !$0.isRemoved }.map(\.record), listing.unreadable)
  }
}

/// Which side quests earned their reward, read from the `sidequest.log` commands in clock order as replay's `logSideQuest` grants it: the first
/// `maxRewardedPerDay` logged for the day they were issued on, under each command's own ruleset. The derived tables hold no quick-log outcomes yet, so
/// this reads the commands; it differs from replay only for a side quest logged on an open day a backward time-zone change left ahead of its
/// `issuedOn`, or once replay has halted.
struct SideQuestRewards: Sendable, Equatable {
  struct Grant: Sendable, Equatable {
    let date: LocalDate
    let xp: Int
    let coins: Int
  }

  let grants: [UUID: Grant]
  let rewardedPerDay: [LocalDate: Int]

  init(_ commands: [(command: MemoirCommand, body: MemoirCommandBody)]) {
    var grants = [UUID: Grant]()
    var perDay = [LocalDate: Int]()
    for (command, body) in commands {
      guard case .sideQuestLog(let entry) = body, grants[entry.id] == nil, let ruleset = Ruleset.version(command.rulesetVersion) else { continue }
      let reward = ruleset.quickLogs[.sideQuest]
      let rewarded = perDay[entry.date] ?? 0
      guard entry.date == command.issuedOn, rewarded < reward.maxRewardedPerDay else { continue }
      perDay[entry.date] = rewarded + 1
      grants[entry.id] = Grant(date: entry.date, xp: reward.xp, coins: reward.coins)
    }
    self.grants = grants
    rewardedPerDay = perDay
  }

  func xp(in span: DateSpan) -> Int {
    Exact.sum(grants.values.filter { span.contains($0.date) }.map(\.xp))
  }
}
