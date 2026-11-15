import SwiftUI

extension View {
  /// Mac keeps the native pull-down bezel because only it draws the menu indicator and the split arrow for `primaryAction`.
  public func shadowMenuButton() -> some View {
    #if os(macOS)
      menuStyle(.button)
        .buttonStyle(.bordered)
        .tint(ShadowColor.textPrimary)
    #else
      buttonStyle(.shadowBordered)
    #endif
  }
}
