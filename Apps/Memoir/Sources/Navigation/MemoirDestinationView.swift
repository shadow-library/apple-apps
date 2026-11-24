import SwiftUI

/// Every destination's screen takes the `MemoirScreenContext` and nothing else, so replacing a screen never touches this switch. A destination the
/// modules hide shows nothing, so a stale link to it is harmless; without `MemoirModules` in the environment (an area's preview) everything shows.
struct MemoirDestinationView: View {
  let destination: MemoirDestination
  let context: MemoirScreenContext
  @Environment(MemoirModules.self) private var modules: MemoirModules?

  var body: some View {
    if modules?.shows(.destination(destination)) ?? true { screen }
  }

  @ViewBuilder
  private var screen: some View {
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
