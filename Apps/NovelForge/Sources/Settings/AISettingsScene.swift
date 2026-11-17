import ShadowDesignSystem
import SwiftUI

struct AISettingsScene: View {
  let vault: VaultModel
  let services: AIServices

  var body: some View {
    AISettingsView(services: services, store: vault.store)
      .id(vault.store.map(ObjectIdentifier.init))
      .shadowTheme()
      .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
  }
}
