import ShadowAppShell
import SwiftUI

enum SettingsRoute: Hashable {
  case timeZone
  case currencies
  case export
  case deleteVault
  case about
}

struct SettingsRouteView: View {
  let route: SettingsRoute
  let context: MemoirScreenContext

  var body: some View {
    switch route {
    case .timeZone: SettingsTimeZoneView(context: context)
    case .currencies: EnabledCurrenciesView(context: context)
    case .export: ExportView(context: context)
    case .deleteVault: DeleteVaultView(context: context)
    case .about: AboutView(identity: .memoir, disclosures: AboutDisclosure.memoir)
    }
  }
}
