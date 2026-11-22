import Foundation
import MemoirCore

/// The five steps (`HEADINGS`, `onboarding-screen.tsx:45-51`): the day, the first quest, when it happens, how strict it is, and the summary.
nonisolated enum OnboardingStep: Int, CaseIterable, Hashable, Sendable {
  case day
  case quest
  case schedule
  case strictness
  case ready

  var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
  var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

nonisolated enum OnboardingRecurrence: Hashable, Sendable, CaseIterable {
  case daily
  case chosen
  case count
}

/// What keeps a step from going on (`problems`, `onboarding-screen.tsx:178-184`).
nonisolated enum OnboardingProblem: Hashable, Sendable {
  case sleepWindow(SleepWindowProblem)
  case nameRequired
  case noDays
  case anchorNeedsTime
}

/// The first quest as the reference drafts it (`draft()`, `onboarding-screen.tsx:200-225`): ten minutes, untimed unless it is an anchor, no reminder.
nonisolated struct OnboardingQuest: Sendable {
  let record: QuestRecord
  let creation: QuestCreation
}

/// Everything the five steps decide; nothing is written until the last one.
nonisolated struct OnboardingDraft: Hashable, Sendable {
  static let strictnessOrder: [Strictness] = [.optional, .goal, .routine, .anchor]
  static let statOrder: [StatAffinity] = [.body, .mind, .wealth, .discipline]
  static let weekdays: [LocalDate.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
  /// `SPREAD_DAYS` (`onboarding-screen.tsx:75-83`): how a count a week falls across the week.
  static let spreadDays: [Set<LocalDate.Weekday>] = [
    [.monday], [.tuesday, .friday], [.monday, .wednesday, .friday], [.monday, .tuesday, .thursday, .friday],
    [.monday, .tuesday, .wednesday, .thursday, .friday], [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday], Set(weekdays),
  ]
  static let nameLimit = 120
  static let questMinutes = 10
  static let lightWeekDays = 3
  static let timesPerWeek = 1...7
  static let standardWake = 6 * 60 + 30
  static let standardSleep = 22 * 60 + 30
  static let standardAnchorStart = 7 * 60

  var currency: CurrencyCode
  var timeZone: String
  var wakeMinute = standardWake
  var sleepMinute = standardSleep
  var name = ""
  var stat = StatAffinity.mind
  var strictness = Strictness.goal
  var recurrence = OnboardingRecurrence.chosen
  var chosenDays: Set<LocalDate.Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
  var timesPerWeek = 4
  var startMinute: Int?

  init(currency: CurrencyCode, timeZone: String) {
    self.currency = currency
    self.timeZone = timeZone
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// `scheduledDays` (`onboarding-screen.tsx:105-109`).
  var scheduledDays: Set<LocalDate.Weekday> {
    switch recurrence {
    case .daily: Set(Self.weekdays)
    case .count: Self.spreadDays[min(max(timesPerWeek, Self.timesPerWeek.lowerBound), Self.timesPerWeek.upperBound) - 1]
    case .chosen: chosenDays
    }
  }

  var orderedScheduledDays: [LocalDate.Weekday] { Self.weekdays.filter(scheduledDays.contains) }

  /// Only an anchor keeps a start time (`onboarding-screen.tsx:160`).
  var questStartMinute: Int? { strictness == .anchor ? startMinute : nil }

  func problem(at step: OnboardingStep) -> OnboardingProblem? {
    switch step {
    case .day: SleepWindowProblem(wake: wakeMinute, sleep: sleepMinute).map(OnboardingProblem.sleepWindow)
    case .quest: trimmedName.isEmpty ? .nameRequired : nil
    case .schedule: scheduledDays.isEmpty ? .noDays : nil
    case .strictness: strictness == .anchor && startMinute == nil ? .anchorNeedsTime : nil
    case .ready: nil
    }
  }

  /// The first scheduled day from `today` on (`firstDay`, `onboarding-screen.tsx:111-115`).
  func firstDay(from today: LocalDate) -> LocalDate? {
    (0..<7).lazy.compactMap { today.adding(days: $0) }.first { scheduledDays.contains($0.weekday) }
  }

  /// `onboarding.complete`'s values (`account.service.ts:159-176`): the home currency, enabled alone, and the day; the budget starts unset.
  var settings: AccountSettingsRecord? {
    guard let window = ScheduleWindow(start: wakeMinute, end: sleepMinute) else { return nil }
    return AccountSettingsRecord(defaultCurrency: currency, enabledCurrencies: [currency], schedule: window)
  }

  func quest(id: UUID = UUID(), startingOn today: LocalDate) throws -> OnboardingQuest {
    let frequency: RecurrenceRule.Frequency = recurrence == .daily ? .daily : .weekly(scheduledDays)
    let schedule = try QuestSchedule(
      strictness: strictness, startTimeMinutes: questStartMinute, durationMinutes: Self.questMinutes, statAffinity: stat,
      optionalStreakOptIn: strictness == .optional, recurrence: try RecurrenceRule(frequency: frequency, startDate: today))
    return OnboardingQuest(record: QuestRecord(id: id, name: trimmedName), creation: QuestCreation(questId: id, schedule: schedule))
  }
}
