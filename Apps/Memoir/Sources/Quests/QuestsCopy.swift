import Foundation
import MemoirCore

/// The reference's words for quests (`lib/data/labels.ts`, `features/quests/quest-presenters.ts`), with dates, times and lengths in the locale's formats.
enum QuestsCopy {
  static func name(_ name: String?) -> String {
    guard let name, !name.isEmpty else { return String(localized: "Unnamed quest", table: "Quests") }
    return name
  }

  static func strictness(_ strictness: Strictness) -> String {
    switch strictness {
    case .anchor: String(localized: "Anchor", table: "Quests")
    case .routine: String(localized: "Routine", table: "Quests")
    case .goal: String(localized: "Goal", table: "Quests")
    case .recovery: String(localized: "Recovery", table: "Quests")
    case .optional: String(localized: "Optional", table: "Quests")
    }
  }

  static func strictnessRule(_ strictness: Strictness) -> String {
    switch strictness {
    case .anchor:
      String(localized: "A fixed time, with thirty minutes of grace. A break spends HP when the day closes, unless your intensity is gentle.", table: "Quests")
    case .routine:
      String(localized: "A window the length of the quest. A break spends HP when the day closes, unless your intensity is gentle.", table: "Quests")
    case .goal: String(localized: "Judged on the day, not the hour. A break never costs HP.", table: "Quests")
    case .recovery: String(localized: "Offered the day after a miss. It never costs HP, keeps no streak and can never trigger another.", table: "Quests")
    case .optional: String(localized: "Reward only. A break never costs HP, and ends a streak only if you keep one for it.", table: "Quests")
    }
  }

  static func stat(_ stat: StatAffinity) -> String {
    switch stat {
    case .discipline: String(localized: "Discipline", table: "Quests")
    case .body: String(localized: "Body", table: "Quests")
    case .wealth: String(localized: "Wealth", table: "Quests")
    case .mind: String(localized: "Mind", table: "Quests")
    }
  }

  static func state(_ state: QuestLogState) -> String {
    switch state {
    case .completed: String(localized: "Kept", table: "Quests")
    case .partial: String(localized: "Partial", table: "Quests")
    case .skipped: String(localized: "Skipped", table: "Quests")
    case .missed: String(localized: "Missed", table: "Quests")
    case .late: String(localized: "Late", table: "Quests")
    case .postponed: String(localized: "Postponed", table: "Quests")
    case .rescheduled: String(localized: "Moved", table: "Quests")
    case .recovery: String(localized: "Recovery", table: "Quests")
    }
  }

  static func status(_ status: OccurrenceStatus) -> String {
    switch status {
    case .open, .upcoming: String(localized: "Open", table: "Quests")
    case .unrecorded: state(.missed)
    case .recorded(let recorded): state(recorded)
    }
  }

  static func reason(_ tag: ReasonTag) -> String {
    switch tag {
    case .forgot: String(localized: "forgot", table: "Quests")
    case .tooTired: String(localized: "too tired", table: "Quests")
    case .taskTooBig: String(localized: "task too big", table: "Quests")
    case .scheduleConflict: String(localized: "schedule conflict", table: "Quests")
    case .avoidedIt: String(localized: "avoided it", table: "Quests")
    case .emotionalResistance: String(localized: "emotional resistance", table: "Quests")
    case .health: String(localized: "health", table: "Quests")
    case .travel: String(localized: "travel", table: "Quests")
    case .familySocial: String(localized: "family or social", table: "Quests")
    case .workEmergency: String(localized: "work emergency", table: "Quests")
    case .notImportantAnymore: String(localized: "not important anymore", table: "Quests")
    case .poorlyPlanned: String(localized: "poorly planned", table: "Quests")
    case .other: String(localized: "other", table: "Quests")
    }
  }

  static func time(_ minute: Int?) -> String? {
    minute.map { QuestCalendar.time($0).formatted(date: .omitted, time: .shortened) }
  }

  static func duration(_ minutes: Int) -> String {
    Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
  }

  static func shortDate(_ day: LocalDate) -> String {
    QuestCalendar.date(day).formatted(.dateTime.day().month(.abbreviated))
  }

  static func percent(_ fraction: Fraction) -> String {
    (Double(fraction.numerator) / Double(fraction.denominator)).formatted(.percent.precision(.fractionLength(0)))
  }

  static func weekday(_ weekday: LocalDate.Weekday, long: Bool = false) -> String {
    let calendar = Calendar.current
    let symbols = long ? calendar.weekdaySymbols : calendar.shortWeekdaySymbols
    return symbols[QuestCalendar.symbolIndex(weekday)]
  }

  /// `recurrenceSummary` (`quest-presenters.ts:120-140`).
  static func recurrence(_ summary: RecurrenceSummary) -> String {
    switch summary {
    case .daily(let interval):
      interval > 1 ? String(localized: "Every \(interval) days", table: "Quests") : String(localized: "Every day", table: "Quests")
    case .weekly(let interval, let days):
      interval > 1 ? String(localized: "Every \(interval) weeks · \(weekdays(days))", table: "Quests") : weekdays(days)
    case .monthlyOnDay(let interval, let day):
      interval > 1
        ? String(localized: "Every \(interval) months on day \(day)", table: "Quests") : String(localized: "Monthly on day \(day)", table: "Quests")
    case .monthlyOnWeekday(let interval, let weekday, let ordinal):
      interval > 1
        ? String(localized: "Every \(interval) months on the \(self.ordinal(ordinal)) \(self.weekday(weekday, long: true))", table: "Quests")
        : String(localized: "Monthly on the \(self.ordinal(ordinal)) \(self.weekday(weekday, long: true))", table: "Quests")
    case .yearly(let interval, _, _):
      interval > 1 ? String(localized: "Every \(interval) years", table: "Quests") : String(localized: "Every year", table: "Quests")
    }
  }

  /// `weekdaySpan` (`quest-presenters.ts:100-118`).
  static func weekdays(_ span: WeekdaySpan) -> String {
    switch span {
    case .everyDay: String(localized: "Every day", table: "Quests")
    case .days(let runs):
      runs.map { run in
        switch run {
        case .single(let day): weekday(day)
        case .range(let from, let through): String(localized: "\(weekday(from))–\(weekday(through))", table: "Quests")
        }
      }.formatted(.list(type: .and, width: .narrow))
    }
  }

  /// `scheduleSummary` (`quest-presenters.ts:142-144`).
  static func schedule(_ quest: QuestSnapshot) -> String {
    let time = time(quest.startMinute) ?? String(localized: "all day", table: "Quests")
    return String(localized: "\(recurrence(quest.recurrenceSummary)) · \(time)", table: "Quests")
  }

  static func streak(_ length: Int, unit: StreakUnit) -> String {
    switch unit {
    case .days: String(localized: "\(length)-day streak", table: "Quests")
    case .occurrences: String(localized: "\(length)-occurrence streak", table: "Quests")
    }
  }

  static func shields(_ count: Int) -> String {
    String(localized: "\(count) shields", table: "Quests")
  }

  /// `questMeta` (`quest-presenters.ts:154-166`).
  static func meta(_ summary: QuestSummary) -> String {
    let streak = summary.streak
    let run: String? =
      switch streak.standing {
      case .running(let days): self.streak(days, unit: streak.unit)
      case .ended(let longest): String(localized: "longest \(self.streak(longest, unit: streak.unit))", table: "Quests")
      case .notStarted: nil
      }
    let parts = [
      schedule(summary.quest), run, streak.shields > 0 ? shields(streak.shields) : nil,
      summary.quest.isActive ? nil : String(localized: "kept as history", table: "Quests"),
    ]
    return parts.compactMap(\.self).joined(separator: " · ")
  }

  /// `rescheduleSummary` (`quest-presenters.ts:210-219`).
  static func reschedules(_ budget: RescheduleBudget) -> String {
    let ahead = budget.bookedAhead > 0 ? String(localized: " · \(budget.bookedAhead) more booked ahead", table: "Quests") : ""
    guard budget.isCapReached, let freesOn = budget.freesOn else {
      return String(localized: "\(budget.used) of \(budget.cap) used in the last 7 days\(ahead)", table: "Quests")
    }
    return String(localized: "Cap reached — frees up for occurrences from \(shortDate(freesOn))\(ahead)", table: "Quests")
  }

  /// Why an action the core withholds is not offered, in the reference's words where it has them.
  static func block(_ block: ActionBlock) -> String? {
    switch block {
    case .lockedInTodaysPlan: String(localized: "Locked with today’s plan.", table: "Quests")
    case .questInactive: String(localized: "Kept as history, so its schedule stays as it was.", table: "Quests")
    case .nothingToLock: String(localized: "Nothing is scheduled today.", table: "Quests")
    case .notAccountDay: String(localized: "Only today’s plan can be locked.", table: "Quests")
    case .notScheduled, .notYetBegun, .dayPassed, .alreadyRecorded, .alreadyRescheduled, .notAllowedFor, .rescheduleCapReached, .nothingRecorded, .notLocked,
      .recoveryClosed:
      nil
    }
  }

  /// `questThresholdLabel` (`quest-presenters.ts:51-54`): "Steps ≥ 8,000".
  static func threshold(_ threshold: QuestThresholdSummary) -> String {
    let name = threshold.builtin.map(metric) ?? threshold.customName ?? String(localized: "A metric", table: "Quests")
    let value = Decimal(string: threshold.value.text, locale: Locale(identifier: "en_US_POSIX")).map { $0.formatted(.number) } ?? threshold.value.text
    return switch threshold.comparison {
    case .atLeast: String(localized: "\(name) ≥ \(value)", table: "Quests")
    case .atMost: String(localized: "\(name) ≤ \(value)", table: "Quests")
    }
  }

  static var thresholdElsewhere: LocalizedStringResource {
    LocalizedStringResource(
      "None on this device. A threshold set on another device stays there while activity and health data don’t sync to this one.", table: "Quests")
  }

  static func metric(_ metric: BuiltinMetric) -> String {
    switch metric {
    case .steps: String(localized: "Steps", table: "Quests")
    case .activeEnergy: String(localized: "Calories burned", table: "Quests")
    case .workoutMinutes: String(localized: "Workout minutes", table: "Quests")
    case .weight: String(localized: "Weight", table: "Quests")
    case .restingHeartRate: String(localized: "Resting heart rate", table: "Quests")
    case .sleep: String(localized: "Sleep duration", table: "Quests")
    case .waistCircumference: String(localized: "Waist circumference", table: "Quests")
    case .water: String(localized: "Water", table: "Quests")
    }
  }

  private static func ordinal(_ ordinal: WeekdayOrdinal) -> String {
    switch ordinal {
    case .first: String(localized: "first", table: "Quests")
    case .second: String(localized: "second", table: "Quests")
    case .third: String(localized: "third", table: "Quests")
    case .fourth: String(localized: "fourth", table: "Quests")
    case .last: String(localized: "last", table: "Quests")
    }
  }
}
