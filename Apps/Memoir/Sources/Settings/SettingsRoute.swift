import SwiftUI

enum SettingsRoute: Hashable {
  case timeZone
  case currencies
}

struct SettingsRouteView: View {
  let route: SettingsRoute
  let context: MemoirScreenContext

  var body: some View {
    switch route {
    case .timeZone: SettingsTimeZoneView(context: context)
    case .currencies: EnabledCurrenciesView(context: context)
    }
  }
}
