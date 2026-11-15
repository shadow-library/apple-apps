import SwiftUI

nonisolated public enum ShadowScreenLevel: Hashable, Sendable, CaseIterable {
  case root
  case pushed
}

private struct ShadowScreenModifier: ViewModifier {
  let level: ShadowScreenLevel

  func body(content: Content) -> some View {
    content
      .scrollContentBackground(.hidden)
      .background(ShadowColor.surfaceApp)
      .modifier(ScrollEdgeModifier())
      .modifier(BarAppearanceModifier(level: level))
  }
}

private struct ScrollEdgeModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(visionOS)
      content
    #else
      content.scrollEdgeEffectStyle(.soft, for: .all)
    #endif
  }
}

private struct BarAppearanceModifier: ViewModifier {
  let level: ShadowScreenLevel

  func body(content: Content) -> some View {
    #if os(iOS)
      content.toolbarTitleDisplayMode(level == .root ? .large : .inline)
    #elseif os(macOS)
      content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    #else
      content
    #endif
  }
}

extension View {
  public func shadowScreen(_ level: ShadowScreenLevel) -> some View {
    modifier(ShadowScreenModifier(level: level))
  }
}
