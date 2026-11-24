import Foundation
import MemoirCore

enum MemoirDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
  case today
  case planningBoard
  case quests
  case journal
  case meals
  case weight
  case bodyAndHealth
  case sideQuests
  case money
  case history
  case insights
  case weeklyReview
  case ask
  case hero
  case settings

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .today: LocalizedStringResource("Today", table: "Navigation")
    case .planningBoard: LocalizedStringResource("Planning Board", table: "Navigation")
    case .quests: LocalizedStringResource("Quests", table: "Navigation")
    case .journal: LocalizedStringResource("Journal", table: "Navigation")
    case .meals: LocalizedStringResource("Meals", table: "Navigation")
    case .weight: LocalizedStringResource("Weight", table: "Navigation")
    case .bodyAndHealth: LocalizedStringResource("Body & health", table: "Navigation")
    case .sideQuests: LocalizedStringResource("Side quests", table: "Navigation")
    case .money: LocalizedStringResource("Money", table: "Navigation")
    case .history: LocalizedStringResource("History", table: "Navigation")
    case .insights: LocalizedStringResource("Insights", table: "Navigation")
    case .weeklyReview: LocalizedStringResource("Weekly Review", table: "Navigation")
    case .ask: LocalizedStringResource("Ask", table: "Navigation")
    case .hero: LocalizedStringResource("Hero", table: "Navigation")
    case .settings: LocalizedStringResource("Settings", table: "Navigation")
    }
  }

  var systemImage: String {
    switch self {
    case .today: "sun.max"
    case .planningBoard: "calendar"
    case .quests: "flag"
    case .journal: "book.closed"
    case .meals: "fork.knife"
    case .weight: "scalemass"
    case .bodyAndHealth: "heart.text.square"
    case .sideQuests: "sparkles"
    case .money: "banknote"
    case .history: "clock.arrow.circlepath"
    case .insights: "chart.line.uptrend.xyaxis"
    case .weeklyReview: "checklist"
    case .ask: "bubble.left.and.text.bubble.right"
    case .hero: "shield"
    case .settings: "gearshape"
    }
  }

  var section: MemoirSection {
    switch self {
    case .today, .planningBoard, .quests: .day
    case .journal, .meals, .weight, .bodyAndHealth, .sideQuests, .money: .capture
    case .history, .insights, .weeklyReview, .ask: .reflect
    case .hero, .settings: .footer
    }
  }

  /// Weekly Review walks quests and money; reflection and Settings read whatever is on.
  var requirement: MemoirModuleRequirement {
    switch self {
    case .today, .planningBoard, .quests, .sideQuests: .module(.quests)
    case .journal: .module(.journal)
    case .meals: .module(.meals)
    case .weight, .bodyAndHealth: .module(.body)
    case .money: .module(.money)
    case .hero: .module(.hero)
    case .weeklyReview: .anyOf([.quests, .money])
    case .history, .insights, .ask: .anyModule
    case .settings: .always
    }
  }

  /// The compact tab whose stack shows this destination, at its root or pushed from it, while that tab shows (`MemoirNavigationMap.tab(of:)`).
  var tab: MemoirTab {
    switch self {
    case .today, .history, .insights, .weeklyReview, .ask, .settings: .today
    case .planningBoard, .quests: .plan
    case .journal, .meals, .weight, .bodyAndHealth, .sideQuests: .log
    case .money: .money
    case .hero: .hero
    }
  }
}

/// The sidebar's groups on iPad and Mac: the day, capture, the reflection half of the loop, and an untitled footer.
enum MemoirSection: String, CaseIterable, Hashable, Identifiable, Sendable {
  case day
  case capture
  case reflect
  case footer

  var id: Self { self }

  var title: LocalizedStringResource? {
    switch self {
    case .day: LocalizedStringResource("Day", table: "Navigation")
    case .capture: LocalizedStringResource("Capture", table: "Navigation")
    case .reflect: LocalizedStringResource("Reflect", table: "Navigation")
    case .footer: nil
    }
  }

  var systemImage: String {
    switch self {
    case .day: "sun.max"
    case .capture: "square.and.pencil"
    case .reflect: "lightbulb"
    case .footer: "ellipsis.circle"
    }
  }
}

/// The iPhone tab bar, in the order a day is lived; what is reached less than daily is pushed from a tab's root.
enum MemoirTab: String, CaseIterable, Hashable, Identifiable, Sendable {
  case today
  case plan
  case log
  case money
  case hero

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .today: LocalizedStringResource("Today", table: "Navigation")
    case .plan: LocalizedStringResource("Plan", table: "Navigation")
    case .log: LocalizedStringResource("Log", table: "Navigation")
    case .money: LocalizedStringResource("Money", table: "Navigation")
    case .hero: LocalizedStringResource("Hero", table: "Navigation")
    }
  }

  var systemImage: String {
    switch self {
    case .today: MemoirDestination.today.systemImage
    case .plan: MemoirDestination.planningBoard.systemImage
    case .log: "square.and.pencil"
    case .money: MemoirDestination.money.systemImage
    case .hero: MemoirDestination.hero.systemImage
    }
  }

  /// The tab's root screen; nil for Log, whose root is chosen by the modules (`MemoirNavigationMap.root(of:)`).
  var root: MemoirDestination? {
    switch self {
    case .today: .today
    case .plan: .planningBoard
    case .log: nil
    case .money: .money
    case .hero: .hero
    }
  }
}

enum MemoirToolbarEntry: Hashable, Identifiable, Sendable {
  case link(MemoirDestination)
  case menu(MemoirSection, [MemoirDestination])

  var id: String {
    switch self {
    case .link(let destination): destination.rawValue
    case .menu(let section, _): section.rawValue
    }
  }
}
