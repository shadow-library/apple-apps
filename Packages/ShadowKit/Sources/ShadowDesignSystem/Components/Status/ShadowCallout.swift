import SwiftUI

public struct ShadowCalloutDismiss {
  let label: Text
  let action: () -> Void

  public init(_ label: LocalizedStringKey, action: @escaping () -> Void) {
    self.label = Text(label)
    self.action = action
  }

  public init(_ label: Text, action: @escaping () -> Void) {
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
    self.init(Text(titleKey), message: message.map { Text($0) }, intent: intent, systemImage: systemImage, dismiss: dismiss, action: action)
  }

  public init(
    _ title: Text,
    message: Text? = nil,
    intent: ShadowIntent = .info,
    systemImage: String? = nil,
    dismiss: ShadowCalloutDismiss? = nil,
    @ViewBuilder action: () -> Action
  ) {
    self.title = title
    self.message = message
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
        .frame(width: ShadowMetrics.tapTarget, height: ShadowMetrics.tapTarget)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(dismiss.label)
    .padding(-(Spacing.space2 + Spacing.space3 / 2))
  }
}

extension ShadowCallout where Action == EmptyView {
  public init(
    _ titleKey: LocalizedStringKey, message: LocalizedStringKey? = nil, intent: ShadowIntent = .info, systemImage: String? = nil,
    dismiss: ShadowCalloutDismiss? = nil
  ) {
    self.init(titleKey, message: message, intent: intent, systemImage: systemImage, dismiss: dismiss) { EmptyView() }
  }

  public init(_ title: Text, message: Text? = nil, intent: ShadowIntent = .info, systemImage: String? = nil, dismiss: ShadowCalloutDismiss? = nil) {
    self.init(title, message: message, intent: intent, systemImage: systemImage, dismiss: dismiss) { EmptyView() }
  }
}

private struct ShadowCalloutActionStyle: ButtonStyle {
  let intent: ShadowIntent

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let height = ShadowMetrics.control(.small)
    let shape = RoundedRectangle(cornerRadius: ShadowDensity.current == .touch ? Radius.full : Radius.md, style: .continuous)
    configuration.label
      .font(Font.shadow(.subheadline).weight(.semibold))
      .foregroundStyle(intent.foreground)
      .padding(.horizontal, ShadowDensity.current == .touch ? Spacing.space4 : Spacing.space3)
      .frame(minHeight: height)
      .overlay { shape.strokeBorder(intent.border, lineWidth: 1) }
      .background(intent.foreground.opacity(configuration.isPressed ? 0.12 : 0), in: shape)
      .contentShape(shape)
      .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
  }
}

nonisolated private enum ShadowCalloutSymbol {
  static let width: CGFloat = 24
}
