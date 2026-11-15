import SwiftUI

nonisolated public struct ShadowToastMetrics: Hashable, Sendable {
  public let minimumHeight: CGFloat
  public let horizontalPadding: CGFloat
  public let verticalPadding: CGFloat
  public let spacing: CGFloat
  public let maximumWidth: CGFloat
  public let edgeInset: CGFloat
  public let maximumCornerRadius: CGFloat
  let textStyle: ShadowTextStyle

  public init(density: ShadowDensity = .current) {
    switch density {
    case .touch:
      minimumHeight = ShadowMetrics.controlTouchMd
      horizontalPadding = Spacing.space4
      verticalPadding = Spacing.space3
      spacing = Spacing.space2
      maximumWidth = 480
      edgeInset = Spacing.space2
      textStyle = .iosSubheadline
    case .compact:
      minimumHeight = ShadowMetrics.controlMacLg
      horizontalPadding = Spacing.space3
      verticalPadding = Spacing.space2
      spacing = Spacing.space2
      maximumWidth = 420
      edgeInset = Spacing.space5
      textStyle = .macBody
    }
    maximumCornerRadius = Radius.panel
  }
}

nonisolated struct ShadowToastShape: InsettableShape {
  var maximumCornerRadius: CGFloat
  var inset: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let frame = rect.insetBy(dx: inset, dy: inset)
    return RoundedRectangle(cornerRadius: min(frame.height / 2, maximumCornerRadius), style: .continuous).path(in: frame)
  }

  func inset(by amount: CGFloat) -> Self {
    var shape = self
    shape.inset += amount
    return shape
  }
}

private struct ShadowMaximumWidth: ViewModifier {
  let maximumWidth: CGFloat

  func body(content: Content) -> some View {
    ShadowMaximumWidthLayout(maximumWidth: maximumWidth) { content }
  }
}

private struct ShadowMaximumWidthLayout: Layout {
  let maximumWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    subviews.first?.sizeThatFits(limited(proposal)) ?? .zero
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }

  private func limited(_ proposal: ProposedViewSize) -> ProposedViewSize {
    ProposedViewSize(width: min(proposal.width ?? maximumWidth, maximumWidth), height: proposal.height)
  }
}

extension ShadowIntent {
  var toastSymbolColor: Color {
    switch self {
    case .neutral: ShadowColor.textPrimary
    case .info: ShadowColor.infoText
    case .success: ShadowColor.successText
    case .warning: ShadowColor.warningText
    case .danger: ShadowColor.dangerText
    }
  }
}

public struct ShadowToastView: View {
  private enum Control: Hashable {
    case action
    case dismiss
  }

  private let toast: ShadowToast
  private let onDismiss: (() -> Void)?
  var onFocusChange: (Bool) -> Void = { _ in }

  @FocusState private var focusedControl: Control?

  public init(_ toast: ShadowToast, onDismiss: (() -> Void)? = nil) {
    self.toast = toast
    self.onDismiss = onDismiss
  }

  public var body: some View {
    let metrics = ShadowToastMetrics()
    HStack(spacing: metrics.spacing) {
      if let systemImage = toast.systemImage {
        Image(systemName: systemImage)
          .foregroundStyle(toast.intent.toastSymbolColor)
          .accessibilityHidden(true)
      }
      Text(toast.message)
        .foregroundStyle(ShadowColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, metrics.verticalPadding)
        .layoutPriority(1)
      if let action = toast.action {
        Button {
          action.perform()
          onDismiss?()
        } label: {
          Text(action.title)
            .fontWeight(.semibold)
            .frame(minHeight: metrics.minimumHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShadowColor.accentText)
        .focused($focusedControl, equals: .action)
      }
      if let dismissLabel = toast.dismissLabel, let onDismiss {
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .imageScale(.small)
            .fontWeight(.semibold)
            .frame(minWidth: metrics.minimumHeight * 0.75, minHeight: metrics.minimumHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShadowColor.textSecondary)
        .focused($focusedControl, equals: .dismiss)
        .accessibilityLabel(Text(dismissLabel))
        .help(Text(dismissLabel))
      }
    }
    .shadowFont(metrics.textStyle)
    .fontWeight(.semibold)
    .padding(.horizontal, metrics.horizontalPadding)
    .frame(minHeight: metrics.minimumHeight)
    .fixedSize(horizontal: false, vertical: true)
    .shadowGlass(.dense, in: ShadowToastShape(maximumCornerRadius: metrics.maximumCornerRadius))
    .modifier(ShadowMaximumWidth(maximumWidth: metrics.maximumWidth))
    .onChange(of: focusedControl) { _, control in onFocusChange(control != nil) }
    .accessibilityElement(children: .contain)
  }
}
