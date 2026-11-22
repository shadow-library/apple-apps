import Foundation
import MemoirCore

/// The reference's words for onboarding (`features/onboarding/onboarding-screen.tsx`).
enum OnboardingCopy {
  static func title(_ step: OnboardingStep) -> String {
    switch step {
    case .day: String(localized: "Set up your day", table: "Onboarding")
    case .quest: String(localized: "Your first quest", table: "Onboarding")
    case .schedule: String(localized: "When it happens", table: "Onboarding")
    case .strictness: String(localized: "How strict is it?", table: "Onboarding")
    case .ready: String(localized: "Ready", table: "Onboarding")
    }
  }

  /// `subtitle` (`onboarding-screen.tsx:170-176`).
  static func subtitle(_ step: OnboardingStep, startsOn: LocalDate.Weekday?, startsToday: Bool) -> String {
    switch step {
    case .day: String(localized: "Two decisions about time, one about money.", table: "Onboarding")
    case .quest: String(localized: "A promise, not a task.", table: "Onboarding")
    case .schedule: String(localized: "Fewer days kept beats more days planned.", table: "Onboarding")
    case .strictness: String(localized: "This is the setting that decides how the app feels.", table: "Onboarding")
    case .ready:
      if startsToday || startsOn == nil {
        String(localized: "One quest, on today, with nothing else in the way.", table: "Onboarding")
      } else {
        String(localized: "One quest, starting \(weekday(startsOn)), with nothing else in the way.", table: "Onboarding")
      }
    }
  }

  static func problem(_ problem: OnboardingProblem) -> String {
    switch problem {
    case .sleepWindow(let problem): problem.message
    case .nameRequired: String(localized: "Name the promise to continue.", table: "Onboarding")
    case .noDays: String(localized: "Choose at least one day.", table: "Onboarding")
    case .anchorNeedsTime: String(localized: "Anchor needs a start time before you can continue.", table: "Onboarding")
    }
  }

  /// `defaultFootNote` and `footNote` (`onboarding-screen.tsx:279-287`): the day and schedule steps show their problem by the field instead.
  static func footNote(_ step: OnboardingStep, problem: OnboardingProblem?) -> String {
    if step != .day, step != .schedule, let problem { return self.problem(problem) }
    return switch step {
    case .day: String(localized: "Nothing is saved until the last step.", table: "Onboarding")
    case .ready: String(localized: "You can change all of this later.", table: "Onboarding")
    case .quest, .schedule, .strictness: String(localized: "Two minutes, and no tour afterwards.", table: "Onboarding")
    }
  }

  static let examples = [
    String(localized: "Read 10 pages", table: "Onboarding"), String(localized: "Walk 20 minutes", table: "Onboarding"),
    String(localized: "No takeaway today", table: "Onboarding"), String(localized: "Write one line", table: "Onboarding"),
    String(localized: "Bed by 22:30", table: "Onboarding"),
  ]

  /// `STATS` (`onboarding-screen.tsx:64-69`).
  static func statDescription(_ stat: StatAffinity) -> String {
    switch stat {
    case .body: String(localized: "Movement, sleep, food, strength", table: "Onboarding")
    case .mind: String(localized: "Reading, writing, study, focus", table: "Onboarding")
    case .wealth: String(localized: "Spending, saving, admin", table: "Onboarding")
    case .discipline: String(localized: "Anchors, tidiness, follow-through", table: "Onboarding")
    }
  }

  /// `STRICTNESS_COSTS` (`onboarding-screen.tsx:73-78`).
  static func cost(_ strictness: Strictness) -> String {
    switch strictness {
    case .optional: String(localized: "no cost, ever", table: "Onboarding")
    case .goal: String(localized: "streak ends, no HP", table: "Onboarding")
    case .routine: String(localized: "streak ends, 1 HP", table: "Onboarding")
    case .anchor: String(localized: "streak ends, 1 HP, fixed time", table: "Onboarding")
    case .recovery: ""
    }
  }

  static func daysAWeek(_ count: Int) -> String {
    String(localized: "\(count) days a week", table: "Onboarding")
  }

  static func days(_ count: Int) -> String {
    String(localized: "\(count) days", table: "Onboarding")
  }

  static func minutes(_ count: Int) -> String {
    Duration.seconds(count * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
  }

  static func frequency(_ count: Int) -> String {
    count == OnboardingDraft.weekdays.count ? String(localized: "Every day", table: "Onboarding") : daysAWeek(count)
  }

  static func weekday(_ day: LocalDate.Weekday?) -> String {
    day.map { QuestsCopy.weekday($0, long: true) } ?? ""
  }

  static func shortWeekdays(_ days: [LocalDate.Weekday]) -> String {
    days.map { QuestsCopy.weekday($0) }.formatted(.list(type: .and, width: .narrow))
  }
}
