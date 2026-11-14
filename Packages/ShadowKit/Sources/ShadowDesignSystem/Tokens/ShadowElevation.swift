import SwiftUI

nonisolated public struct ShadowElevation: Hashable, Sendable {
  nonisolated public struct Layer: Hashable, Sendable {
    public let color: ShadowRGBA
    public let x: CGFloat
    public let y: CGFloat
    public let blur: CGFloat
    public let spread: CGFloat

    // SwiftUI has no spread, so a negative CSS spread shrinks the blur instead; CSS blur is twice the SwiftUI radius.
    var radius: CGFloat { max(0, blur + spread) / 2 }
  }

  public let light: [Layer]
  public let dark: [Layer]

  public func layers(for colorScheme: ColorScheme) -> [Layer] {
    colorScheme == .dark ? dark : light
  }
}

private struct ShadowElevationModifier: ViewModifier {
  let elevation: ShadowElevation
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let layers = elevation.layers(for: colorScheme)
    // Both slots always exist, so switching appearance never changes the content's view identity.
    content
      .modifier(ShadowLayerModifier(layer: layers.first))
      .modifier(ShadowLayerModifier(layer: layers.dropFirst().first))
  }
}

private struct ShadowLayerModifier: ViewModifier {
  let layer: ShadowElevation.Layer?

  func body(content: Content) -> some View {
    content.shadow(color: layer.map { Color($0.color) } ?? .clear, radius: layer?.radius ?? 0, x: layer?.x ?? 0, y: layer?.y ?? 0)
  }
}

extension View {
  public func shadowElevation(_ elevation: ShadowElevation) -> some View {
    modifier(ShadowElevationModifier(elevation: elevation))
  }
}
