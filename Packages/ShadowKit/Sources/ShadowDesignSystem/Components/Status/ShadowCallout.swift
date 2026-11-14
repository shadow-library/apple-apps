import SwiftUI

public struct ShadowCalloutDismiss {
  let label: LocalizedStringKey
  let action: () -> Void

  public init(_ label: LocalizedStringKey, action: @escaping () -> Void) {
    self.label = label
    self.action = action
  }
}

public struct ShadowCallout<Action: View>: View {
  private let title: Text
  private let message: Text?
  private let intent: ShadowIntent
  private let systemImage: String
  private let dismiss: ShadowCalloutDismiss?
  private let action: Action

  public init(
    _ titleKey: LocalizedStringKey,
    message: LocalizedStringKey? = nil,
    intent: ShadowIntent = .info,
    systemImage: String? = nil,
    dismiss: ShadowCalloutDismiss? = nil,
    @ViewBuilder action: () -> Action
  ) {
    title = Text(titleKey)
    self.message = message.map { Text($0) }
    self.intent = intent
    self.systemImage = systemImage ?? intent.systemImage
    self.dismiss = dismiss
    self.action = action()
  }

  public var body: some View {
    let metrics = ShadowCardMetrics()
    let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    HStack(alignment: .top, spacing: Spacing.space3) {
      Image(systemName: systemImage)
        .shadowFont(.headline)
        .fontWeight(.regular)
        .frame(width: ShadowCalloutSymbol.width)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Spacing.space1) {
        title
          .shadowFont(.headline)
        if let message {
          message
            .shadowFont(.footnote)
            .fixedSize(horizontal: false, vertical: true)
        }
        if Action.self != EmptyView.self {
          action
            .buttonStyle(ShadowCalloutActionStyle(intent: intent))
            .padding(.top, Spacing.space1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let dismiss { dismissButton(dismiss) }
    }
    .foregroundStyle(intent.foreground)
    .padding(.horizontal, metrics.horizontalPadding)
    .padding(.vertical, Spacing.space3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.shadowMaterialLayer, .content)
    .background(intent.background, in: shape)
    .overlay { shape.strokeBorder(intent.border, lineWidth: 1) }
    .accessibilityElement(children: .contain)
  }

  private func dismissButton(_ dismiss: ShadowCalloutDismiss) -> some View {
    Button(action: dismiss.action) {
      Image(systemName: "xmark")
        .imageScale(.small)
        .fontWeight(.semibold)
        .frame(width: ShadowMetrics.tapTarget - Spacing.space3, height: ShadowMetrics.tapTarget - Spacing.space3)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(dismiss.label))
    .padding(-Spacing.space2)
  }
}

extension ShadowCallout where Action == EmptyView {
  public init(
    _ titleKey: LocalizedStringKey, message: LocalizedStringKey? = nil, intent: ShadowIntent = .info, systemImage: String? = nil,
    dismiss: ShadowCalloutDismiss? = nil
  ) {
    self.init(titleKey, message: message, intent: intent, systemImage: systemImage, dismiss: dismiss) { EmptyView() }
  }
}

private struct ShadowCalloutActionStyle: ButtonStyle {
  let intent: ShadowIntent

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let height = ShadowMetrics.control(.small)
    configuration.label
      .font(Font.shadow(.subheadline).weight(.semibold))
      .foregroundStyle(intent.foreground)
      .padding(.horizontal, ShadowDensity.current == .touch ? Spacing.space4 : Spacing.space3)
      .frame(minHeight: height)
      .overlay { Capsule().strokeBorder(intent.border, lineWidth: 1) }
      .background(intent.foreground.opacity(configuration.isPressed ? 0.12 : 0), in: .capsule)
      .contentShape(.capsule)
      .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
  }
}

nonisolated private enum ShadowCalloutSymbol {
  static let width: CGFloat = 24
}
