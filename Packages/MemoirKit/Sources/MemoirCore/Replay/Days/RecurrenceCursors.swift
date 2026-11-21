import Foundation

/// Where the walk last expanded each quest's recurrence, so the next day resumes there rather than from the quest's start date. A cache: resuming gives the
/// same occurrences as a full expansion, so it takes no part in equality, and a cursor is used only with the rule it was taken from.
struct RecurrenceCursors: Sendable, Hashable {
  private struct Entry: Sendable {
    let rule: RecurrenceRule
    let cursor: RecurrenceOccurrence
  }

  private var entries: [UUID: Entry] = [:]

  static func == (_: RecurrenceCursors, _: RecurrenceCursors) -> Bool { true }

  func hash(into _: inout Hasher) {}

  /// Moves the quest's cursor to `date`, which the walk only ever moves forward.
  mutating func advance(_ quest: ReplayQuest, to date: LocalDate) -> Bool {
    let expansion = expand(quest, on: date)
    if let cursor = expansion.cursor { entries[quest.id] = Entry(rule: quest.schedule.recurrence, cursor: cursor) }
    return !expansion.occurrences.isEmpty
  }

  func occurs(_ quest: ReplayQuest, on date: LocalDate) -> Bool {
    !expand(quest, on: date).occurrences.isEmpty
  }

  private func expand(_ quest: ReplayQuest, on date: LocalDate) -> RecurrenceExpansion {
    let rule = quest.schedule.recurrence
    let resume = entries[quest.id].flatMap { $0.rule == rule && $0.cursor.date <= date ? $0.cursor : nil }
    return rule.expand(from: date, through: date, resumingAt: resume)
  }
}

extension ReplayState {
  /// `scheduledQuests(on:)` for the walk, whose days only move forward.
  mutating func walkScheduledQuests(on date: LocalDate) -> [ReplayQuest] {
    var cursors = recurrenceCursors
    let scheduled = quests.values.filter { $0.isActive && $0.schedule.strictness != .recovery && cursors.advance($0, to: date) }.sorted { $0.createdOrder < $1.createdOrder }
    recurrenceCursors = cursors
    return scheduled
  }
}
