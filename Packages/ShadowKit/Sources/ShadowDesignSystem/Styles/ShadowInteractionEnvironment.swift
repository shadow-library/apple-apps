import SwiftUI

extension EnvironmentValues {
  @Entry var shadowHoverEffectsEnabled = true
}

extension View {
  @_spi(Preview) public func shadowPreviewHoverEffects(_ isEnabled: Bool) -> some View {
    environment(\.shadowHoverEffectsEnabled, isEnabled)
  }
}
