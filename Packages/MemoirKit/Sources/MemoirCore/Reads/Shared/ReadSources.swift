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

/// Replay's side-quest outcomes from the projection: whether each log earned its reward, and the slots and XP each day's rewards took.
struct SideQuestOutcomes: Sendable, Equatable {
  let logs: [UUID: QuickLogRow]
  let days: [LocalDate: QuickLogDayRow]

  static func load(in transaction: ReadTransaction) throws(StoreError) -> SideQuestOutcomes {
    let logs = try MemoirDerived.quickLogs(.sideQuest, from: .earliest, through: .latest, in: transaction)
    let days = try MemoirDerived.quickLogDays(.sideQuest, from: .earliest, through: .latest, in: transaction)
    return SideQuestOutcomes(
      logs: Dictionary(uniqueKeysWithValues: logs.map { ($0.id, $0) }), days: Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) }))
  }

  func reward(of sideQuest: UUID) -> RewardAmount? {
    logs[sideQuest]?.reward
  }

  func rewarded(on date: LocalDate) -> Int {
    days[date]?.rewarded ?? 0
  }

  func xp(in span: DateSpan) -> Int {
    Exact.sum(days.values.filter { span.contains($0.date) }.map(\.reward.xp))
  }
}
