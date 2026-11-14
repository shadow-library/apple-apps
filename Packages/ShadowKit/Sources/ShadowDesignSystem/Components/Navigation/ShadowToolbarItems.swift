import SwiftUI

extension View {
  public func shadowBarItem() -> some View {
    tint(ShadowColor.textPrimary)
  }

  public func shadowToolbarProminent() -> some View {
    #if os(visionOS)
      buttonStyle(.borderedProminent).tint(ShadowColor.accent)
    #else
      buttonStyle(.glassProminent).tint(ShadowColor.accent)
    #endif
  }
}
