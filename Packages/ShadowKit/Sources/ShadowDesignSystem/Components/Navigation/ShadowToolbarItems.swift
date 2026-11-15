import SwiftUI

// The system picks the prominent label colour from the tint's luminance and chooses dark text on the dark-mode accent, so the label is set explicitly.
private struct ShadowToolbarProminentStyle: PrimitiveButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    let button = Button(role: configuration.role, action: configuration.trigger) {
      configuration.label.foregroundStyle(ShadowColor.onAccent)
    }
    #if os(visionOS)
      button.buttonStyle(.borderedProminent)
    #else
      button.buttonStyle(.glassProminent)
    #endif
  }
}

extension View {
  public func shadowBarItem() -> some View {
    tint(ShadowColor.textPrimary)
  }

  public func shadowToolbarProminent() -> some View {
    buttonStyle(ShadowToolbarProminentStyle()).tint(ShadowColor.accent)
  }
}
