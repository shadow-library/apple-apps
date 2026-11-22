import MemoirCore
import SwiftUI

/// Every destination's screen takes the vault's stores and nothing else, so replacing a screen never touches this switch.
struct MemoirDestinationView: View {
  let destination: MemoirDestination
  let stores: MemoirStores

  var body: some View {
    switch destination {
    case .today: TodayView(stores: stores)
    case .planningBoard: PlanningBoardView(stores: stores)
    case .quests: QuestsView(stores: stores)
    case .journal: JournalView(stores: stores)
    case .meals: MealsView(stores: stores)
    case .weight: WeightView(stores: stores)
    case .bodyAndHealth: BodyAndHealthView(stores: stores)
    case .sideQuests: SideQuestsView(stores: stores)
    case .money: MoneyView(stores: stores)
    case .history: HistoryView(stores: stores)
    case .insights: InsightsView(stores: stores)
    case .weeklyReview: WeeklyReviewView(stores: stores)
    case .ask: AskView(stores: stores)
    case .hero: HeroView(stores: stores)
    case .settings: SettingsView(stores: stores)
    }
  }
}
