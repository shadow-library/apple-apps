import SwiftUI

public struct ShadowCardButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    ShadowCardButtonBody(configuration: configuration)
  }
}

extension ButtonStyle where Self == ShadowCardButtonStyle {
  public static var shadowCard: Self { Self() }
}

private struct ShadowCardButtonBody: View {
  let configuration: ButtonStyleConfiguration

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.shadowPreviewInteraction) private var previewInteraction
  @State private var isHovered = false

  private var interaction: ShadowButtonInteraction {
    if let previewInteraction { return previewInteraction }
    if configuration.isPressed { return .pressed }
    return isHovered && isEnabled ? .hovered : .idle
  }

  var body: some View {
    let interaction = interaction
    let shape = RoundedRectangle(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous)
    configuration.label
      .foregroundStyle(ShadowColor.textPrimary)
      .multilineTextAlignment(.leading)
      .modifier(ShadowCardChrome(interaction: interaction))
      .contentShape(shape)
      .scaleEffect(interaction == .pressed && !reduceMotion && ShadowDensity.current == .touch ? 0.98 : 1)
      .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
      .modifier(CardPointerModifier(shape: shape, isHovered: $isHovered))
      .shadowAnimation(.fast, value: interaction)
  }
}

private struct CardPointerModifier<HoverShape: Shape>: ViewModifier {
  let shape: HoverShape
  @Binding var isHovered: Bool

  func body(content: Content) -> some View {
    #if os(iOS) || os(visionOS)
      content
        .contentShape(.hoverEffect, shape)
        .hoverEffect(.lift)
    #elseif os(macOS)
      content.onHover { isHovered = $0 }
    #else
      content
    #endif
  }
}
