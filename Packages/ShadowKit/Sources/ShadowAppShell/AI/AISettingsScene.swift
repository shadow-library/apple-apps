import ShadowDesignSystem
import ShadowStore
import SwiftUI

public struct AISettingsScene: View {
  let services: AIServices
  let store: VaultStore?

  public init(services: AIServices, store: VaultStore?) {
    self.services = services
    self.store = store
  }

  public var body: some View {
    AISettingsView(services: services, store: store)
      .id(store.map(ObjectIdentifier.init))
      .shadowTheme()
      .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
  }
}
