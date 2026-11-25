import ShadowAppShell
import SwiftUI

enum SettingsRoute: Hashable {
  case features
  case timeZone
  case currencies
  case export
  case deleteVault
  case about
}

struct SettingsRouteView: View {
  let route: SettingsRoute
  let context: MemoirScreenContext
  @Environment(MemoirModuleEffects.self) private var effects: MemoirModuleEffects?

  var body: some View {
    switch route {
    case .features: FeaturesView(context: context, effects: effects)
    case .timeZone: SettingsTimeZoneView(context: context)
    case .currencies: EnabledCurrenciesView(context: context)
    case .export: ExportView(context: context)
    case .deleteVault: DeleteVaultView(context: context)
    case .about: AboutView(identity: .memoir, disclosures: AboutDisclosure.memoir)
    }
  }
}
