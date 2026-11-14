import SwiftUI

nonisolated public struct ShadowGlass: Hashable, Sendable {
  public enum Kind: Hashable, Sendable, CaseIterable {
    case regular
    case dense
    case prominent
    case clear
  }

  public let kind: Kind
  public let isInteractive: Bool

  private init(kind: Kind, isInteractive: Bool = false) {
    self.kind = kind
    self.isInteractive = isInteractive
  }

  public static let regular = Self(kind: .regular)
  public static let dense = Self(kind: .dense)
  public static let prominent = Self(kind: .prominent)
  public static let clear = Self(kind: .clear)

  public func interactive(_ isEnabled: Bool = true) -> Self {
    Self(kind: kind, isInteractive: isEnabled)
  }

  static let denseBackingOpacity = 0.72
}

extension ShadowGlass {
  var foreground: Color {
    switch kind {
    case .regular, .dense: ShadowColor.textPrimary
    case .prominent, .clear: ShadowColor.onAccent
    }
  }

  #if !os(visionOS)
    var material: Glass {
      let glass: Glass =
        switch kind {
        case .regular, .dense: .regular
        case .prominent: .regular.tint(ShadowColor.accent)
        case .clear: .clear
        }
      return glass.interactive(isInteractive)
    }
  #endif
}

private struct ShadowGlassModifier<GlassShape: InsettableShape>: ViewModifier {
  let glass: ShadowGlass
  let shape: GlassShape
  @Environment(\.shadowMaterialLayer) private var layer

  func body(content: Content) -> some View {
    if layer.allowsGlass {
      content
        .foregroundStyle(glass.foreground)
        .background { if glass.kind == .dense { shape.fill(ShadowColor.surfaceRaised.opacity(ShadowGlass.denseBackingOpacity)) } }
        .environment(\.shadowMaterialLayer, .glass)
        .environment(\.shadowGlassForeground, glass.foreground)
        .modifier(MaterialModifier(glass: glass, shape: shape))
        .background { if glass.kind == .clear { shape.fill(ShadowColor.glassDim) } }
    } else {
      content
    }
  }
}

private struct MaterialModifier<GlassShape: InsettableShape>: ViewModifier {
  let glass: ShadowGlass
  let shape: GlassShape

  func body(content: Content) -> some View {
    #if os(visionOS)
      if glass.kind == .prominent {
        content.background(ShadowColor.accent, in: shape)
      } else {
        content.glassBackgroundEffect(in: shape)
      }
    #else
      content.glassEffect(glass.material, in: shape)
    #endif
  }
}

extension View {
  public func shadowGlass(_ glass: ShadowGlass = .regular, in shape: some InsettableShape) -> some View {
    modifier(ShadowGlassModifier(glass: glass, shape: shape))
  }

  public func shadowGlass(_ glass: ShadowGlass = .regular) -> some View {
    shadowGlass(glass, in: Capsule(style: .continuous))
  }
}
