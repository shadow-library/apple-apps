#if DEBUG
  import Foundation
  import MemoirCore

  /// A few quests for the Today preview, written through the screen's writer like the owner's own.
  enum TodayPreviewData {
    static func seed(_ context: MemoirScreenContext) async {
      do {
        let today = try await context.today().date
        try await context.writer.issue(.accountSetTimeZone(try TimeZoneChange(identifier: TimeZone.current.identifier)))
        let quests: [(String, Strictness, Int?, StatAffinity)] = [
          ("Morning walk", .anchor, 7 * 60, .body), ("Read twenty pages", .routine, 21 * 60, .mind), ("Review the budget", .goal, nil, .wealth),
          ("Stretch", .optional, nil, .body),
        ]
        var ids = [UUID]()
        for (name, strictness, start, stat) in quests {
          let id = UUID()
          ids.append(id)
          let schedule = try QuestSchedule(
            strictness: strictness, startTimeMinutes: start, durationMinutes: 30, statAffinity: stat, recurrence: try RecurrenceRule(frequency: .daily, startDate: today))
          try await context.writer.issue(.questCreate(QuestCreation(questId: id, schedule: schedule)), creating: QuestRecord(id: id, name: name))
        }
        try await context.writer.issue(.questComplete(Occurrence(quest: ids[0], date: today)))
      } catch {
        return
      }
    }
  }
#endif
