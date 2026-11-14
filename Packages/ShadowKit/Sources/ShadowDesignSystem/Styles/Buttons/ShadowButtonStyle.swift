import SwiftUI

public struct ShadowButtonStyle: ButtonStyle {
  public let variant: ShadowButtonVariant
  let layout: ShadowButtonLayout

  public init(_ variant: ShadowButtonVariant) {
    self.init(variant, layout: .text)
  }

  init(_ variant: ShadowButtonVariant, layout: ShadowButtonLayout) {
    self.variant = variant
    self.layout = layout
  }

  public func makeBody(configuration: Configuration) -> some View {
    ShadowButtonBody(configuration: configuration, variant: variant, layout: layout)
  }
}

extension ButtonStyle where Self == ShadowButtonStyle {
  public static var shadowFilled: Self { Self(.filled) }
  public static var shadowTinted: Self { Self(.tinted) }
  public static var shadowBordered: Self { Self(.bordered) }
  public static var shadowPlain: Self { Self(.plain) }
  /// For floating chrome only; `ToolbarItem` already wraps its buttons in system glass, so use native toolbar styling there.
  public static var shadowGlass: Self { Self(.glass) }
  /// For floating chrome only; in a toolbar use `.buttonStyle(.glassProminent)` for the one tinted action.
  public static var shadowGlassProminent: Self { Self(.glassProminent) }
}

private struct ShadowButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let variant: ShadowButtonVariant
  let layout: ShadowButtonLayout

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @Environment(\.shadowMaterialLayer) private var layer
  @Environment(\.shadowGlassForeground) private var glassForeground
  @Environment(\.shadowButtonIsLoading) private var isLoading
  @Environment(\.shadowPreviewInteraction) private var previewInteraction
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityShowButtonShapes) private var showsButtonShapes
  @State private var isHovered = false

  private var appearance: ShadowButtonAppearance { variant.appearance(in: layer) }

  private var metrics: ShadowButtonMetrics {
    ShadowButtonMetrics(size: ShadowControlSize(controlSize), layout: layout, isGlass: appearance.isGlass)
  }

  private var interaction: ShadowButtonInteraction {
    if let previewInteraction { return previewInteraction }
    if configuration.isPressed { return .pressed }
    return isHovered && isEnabled ? .hovered : .idle
  }

  private var palette: ShadowButtonPalette {
    ShadowButtonPalette(
      appearance: appearance,
      isDestructive: configuration.role == .destructive,
      interaction: interaction,
      increasedContrast: contrast == .increased,
      showsButtonShapes: showsButtonShapes,
      glassForeground: glassForeground
    )
  }

  var body: some View {
    let metrics = metrics
    let palette = palette
    let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    styledLabel(metrics: metrics, palette: palette)
      .overlay {
        if isLoading { ShadowButtonSpinner(color: palette.foreground, size: metrics.visualHeight / 2) }
      }
      .padding(.horizontal, metrics.horizontalPadding)
      .padding(.vertical, layout == .text ? metrics.verticalPadding : 0)
      .frame(width: metrics.visualWidth, height: layout == .icon ? metrics.visualHeight : nil)
      .frame(minHeight: metrics.visualHeight)
      .background {
        if let fill = palette.fill { shape.fill(fill) }
      }
      .overlay {
        if let border = palette.border { shape.strokeBorder(border, lineWidth: 1) }
      }
      .modifier(ButtonGlassModifier(appearance: appearance, shape: shape))
      .opacity(isEnabled || isLoading || appearance.isGlass ? 1 : ShadowOpacity.disabled)
      .contentShape(shape)
      .modifier(PointerModifier(shape: shape, isHovered: $isHovered))
      .frame(minWidth: metrics.hitSize, minHeight: metrics.layoutHeight)
      .contentShape(.rect)
      .shadowAnimation(.fast, value: interaction)
  }

  private func styledLabel(metrics: ShadowButtonMetrics, palette: ShadowButtonPalette) -> some View {
    configuration.label
      .font(metrics.labelFont)
      .modifier(IconOnlyModifier(isIconOnly: layout == .icon))
      .multilineTextAlignment(.center)
      .foregroundStyle(isLoading ? .clear : palette.foreground)
      .opacity(appearance.isGlass && !isEnabled && !isLoading ? ShadowOpacity.disabled : 1)
  }
}

private struct IconOnlyModifier: ViewModifier {
  let isIconOnly: Bool

  func body(content: Content) -> some View {
    if isIconOnly {
      content.labelStyle(.iconOnly)
    } else {
      content
    }
  }
}

private struct ButtonGlassModifier<GlassShape: InsettableShape>: ViewModifier {
  let appearance: ShadowButtonAppearance
  let shape: GlassShape

  func body(content: Content) -> some View {
    switch appearance {
    case .glass: content.shadowGlass(.regular.interactive(), in: shape)
    case .glassProminent: content.shadowGlass(.prominent.interactive(), in: shape)
    default: content
    }
  }
}

private struct PointerModifier<HoverShape: Shape>: ViewModifier {
  let shape: HoverShape
  @Binding var isHovered: Bool

  func body(content: Content) -> some View {
    #if os(iOS) || os(visionOS)
      content
        .contentShape(.hoverEffect, shape)
        .onHover { isHovered = $0 }
    #elseif os(macOS)
      content.onHover { isHovered = $0 }
    #else
      content
    #endif
  }
}
