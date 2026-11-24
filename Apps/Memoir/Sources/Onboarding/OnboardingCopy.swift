import Foundation
import MemoirCore

/// The reference's words for onboarding (`features/onboarding/onboarding-screen.tsx`).
enum OnboardingCopy {
  static func title(_ step: OnboardingStep) -> String {
    switch step {
    case .purpose: String(localized: "What do you want Memoir for?", table: "Onboarding")
    case .day: String(localized: "Set up your day", table: "Onboarding")
    case .currency: String(localized: "Your home currency", table: "Onboarding")
    case .quest: String(localized: "Your first quest", table: "Onboarding")
    case .schedule: String(localized: "When it happens", table: "Onboarding")
    case .strictness: String(localized: "How strict is it?", table: "Onboarding")
    case .budget: String(localized: "Your Home budget", table: "Onboarding")
    case .ready: String(localized: "Ready", table: "Onboarding")
    }
  }

  /// `subtitle` (`onboarding-screen.tsx:170-176`), with the steps memoir-web does not have.
  static func subtitle(_ step: OnboardingStep, startsOn: LocalDate.Weekday?, startsToday: Bool, hasQuest: Bool) -> String {
    switch step {
    case .purpose: String(localized: "Only what you choose shows, and Settings can change it later.", table: "Onboarding")
    case .day: String(localized: "Two decisions about time.", table: "Onboarding")
    case .currency: String(localized: "One decision about money, made once.", table: "Onboarding")
    case .quest: String(localized: "A promise, not a task.", table: "Onboarding")
    case .schedule: String(localized: "Fewer days kept beats more days planned.", table: "Onboarding")
    case .strictness: String(localized: "This is the setting that decides how the app feels.", table: "Onboarding")
    case .budget: String(localized: "A limit for each month, or none yet.", table: "Onboarding")
    case .ready:
      if !hasQuest {
        String(localized: "What you chose, with nothing else in the way.", table: "Onboarding")
      } else if startsToday || startsOn == nil {
        String(localized: "One quest, on today, with nothing else in the way.", table: "Onboarding")
      } else {
        String(localized: "One quest, starting \(weekday(startsOn)), with nothing else in the way.", table: "Onboarding")
      }
    }
  }

  static func problem(_ problem: OnboardingProblem, in draft: OnboardingDraft) -> String {
    switch problem {
    case .modules(let refusal): self.refusal(refusal)
    case .sleepWindow(let problem): problem.message
    case .nameRequired: String(localized: "Name the promise to continue.", table: "Onboarding")
    case .noDays: String(localized: "Choose at least one day.", table: "Onboarding")
    case .anchorNeedsTime: String(localized: "Anchor needs a start time before you can continue.", table: "Onboarding")
    case .budgetAmount(let refusal): MoneyLabels.amountIssue(refusal, currency: draft.currency, format: draft.format)
    case .budgetZero: String(localized: "Enter a limit above zero, or leave it empty for no limit yet.", table: "Onboarding")
    }
  }

  /// Why `ModuleSelection` refuses the modules chosen by hand.
  static func refusal(_ refusal: ModuleSelectionError) -> String {
    switch refusal {
    case .empty: String(localized: "Choose at least one part of Memoir to continue.", table: "Onboarding")
    case .questsNeedHero: String(localized: "Quests need Hero: experience and levels are what a kept promise earns.", table: "Onboarding")
    case .heroNeedsQuestsOrMoney: String(localized: "Hero needs Quests or Money, the parts it earns from.", table: "Onboarding")
    }
  }

  /// `defaultFootNote` and `footNote` (`onboarding-screen.tsx:279-287`): the steps with a field show their problem by it instead.
  static func footNote(_ step: OnboardingStep, problem: OnboardingProblem?, in draft: OnboardingDraft) -> String {
    if step == .quest || step == .strictness, let problem { return self.problem(problem, in: draft) }
    return switch step {
    case .purpose: String(localized: "Nothing is saved until the last step.", table: "Onboarding")
    case .ready: String(localized: "You can change all of this later.", table: "Onboarding")
    case .day, .currency, .quest, .schedule, .strictness, .budget: String(localized: "Two minutes, and no tour afterwards.", table: "Onboarding")
    }
  }

  static func preset(_ preset: OnboardingPreset) -> String {
    switch preset {
    case .habits: String(localized: "Build habits as a game", table: "Onboarding")
    case .spending: String(localized: "Manage my spending", table: "Onboarding")
    case .both: String(localized: "Both", table: "Onboarding")
    case .everything: String(localized: "Everything", table: "Onboarding")
    }
  }

  static func presetDescription(_ preset: OnboardingPreset) -> String {
    switch preset {
    case .habits: String(localized: "Quests you promise yourself, and a hero who levels up as you keep them.", table: "Onboarding")
    case .spending: String(localized: "Budgets, expenses and subscriptions, with nothing else on screen.", table: "Onboarding")
    case .both: String(localized: "Habits as a game, with spending that counts in it too.", table: "Onboarding")
    case .everything: String(localized: "Quests, money, journal, meals and body together.", table: "Onboarding")
    }
  }

  static func module(_ module: MemoirModule) -> String {
    switch module {
    case .hero: String(localized: "Hero", table: "Onboarding")
    case .quests: String(localized: "Quests", table: "Onboarding")
    case .money: String(localized: "Money", table: "Onboarding")
    case .journal: String(localized: "Journal", table: "Onboarding")
    case .meals: String(localized: "Meals", table: "Onboarding")
    case .body: String(localized: "Body", table: "Onboarding")
    }
  }

  static func moduleDescription(_ module: MemoirModule) -> String {
    switch module {
    case .hero: String(localized: "Experience, levels, coins and titles for what you keep up.", table: "Onboarding")
    case .quests: String(localized: "Daily promises, a plan for the week, recovery and a weekly review.", table: "Onboarding")
    case .money: String(localized: "Budgets, expenses, subscriptions, receipts and savings.", table: "Onboarding")
    case .journal: String(localized: "Entries in your own words.", table: "Onboarding")
    case .meals: String(localized: "What you ate, in a line.", table: "Onboarding")
    case .body: String(localized: "Weight, measurements and activity.", table: "Onboarding")
    }
  }

  /// The chosen modules in the order the purpose step lists them.
  static func modules(_ modules: Set<MemoirModule>) -> String {
    OnboardingDraft.moduleOrder.filter(modules.contains).map(module).formatted(.list(type: .and))
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
