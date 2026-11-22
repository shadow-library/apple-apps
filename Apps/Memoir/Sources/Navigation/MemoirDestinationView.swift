import SwiftUI

/// Every destination's screen takes the `MemoirScreenContext` and nothing else, so replacing a screen never touches this switch.
struct MemoirDestinationView: View {
  let destination: MemoirDestination
  let context: MemoirScreenContext

  var body: some View {
    switch destination {
    case .today: TodayView(context: context)
    case .planningBoard: PlanningBoardView(context: context)
    case .quests: QuestsView(context: context)
    case .journal: JournalView(context: context)
    case .meals: MealsView(context: context)
    case .weight: WeightView(context: context)
    case .bodyAndHealth: BodyAndHealthView(context: context)
    case .sideQuests: SideQuestsView(context: context)
    case .money: MoneyView(context: context)
    case .history: HistoryView(context: context)
    case .insights: InsightsView(context: context)
    case .weeklyReview: WeeklyReviewView(context: context)
    case .ask: AskView(context: context)
    case .hero: HeroView(context: context)
    case .settings: SettingsView(context: context)
    }
  }
}
