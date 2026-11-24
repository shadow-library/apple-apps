import SwiftUI

/// A route the modules hide shows nothing; the navigator drops it from the stack it was pushed on.
struct MemoirRouteView: View {
  let route: MemoirRoute
  let context: MemoirScreenContext
  @Environment(MemoirModules.self) private var modules: MemoirModules?

  var body: some View {
    if modules?.shows(route) ?? true { screen }
  }

  @ViewBuilder
  private var screen: some View {
    switch route {
    case .destination(let destination): MemoirDestinationView(destination: destination, context: context)
    case .quest(let route): QuestRouteView(route: route, context: context)
    case .money(let route): MoneyRouteView(route: route, context: context)
    case .hero(let route): HeroRouteView(route: route, context: context)
    case .log(let route): LogRouteView(route: route, context: context)
    case .reflect(let route): ReflectRouteView(route: route, context: context)
    case .ask(let route): AskRouteView(route: route, context: context)
    case .settings(let route): SettingsRouteView(route: route, context: context)
    }
  }
}
