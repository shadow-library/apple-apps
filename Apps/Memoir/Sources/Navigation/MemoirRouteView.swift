import MemoirCore
import SwiftUI

struct MemoirRouteView: View {
  let route: MemoirRoute
  let stores: MemoirStores

  var body: some View {
    switch route {
    case .destination(let destination): MemoirDestinationView(destination: destination, stores: stores)
    case .quest(let route): QuestRouteView(route: route, stores: stores)
    case .money(let route): MoneyRouteView(route: route, stores: stores)
    case .hero(let route): HeroRouteView(route: route, stores: stores)
    case .log(let route): LogRouteView(route: route, stores: stores)
    case .reflect(let route): ReflectRouteView(route: route, stores: stores)
    case .ask(let route): AskRouteView(route: route, stores: stores)
    case .settings(let route): SettingsRouteView(route: route, stores: stores)
    }
  }
}
