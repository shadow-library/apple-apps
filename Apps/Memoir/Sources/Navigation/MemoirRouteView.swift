import SwiftUI

struct MemoirRouteView: View {
  let route: MemoirRoute
  let context: MemoirScreenContext

  var body: some View {
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
