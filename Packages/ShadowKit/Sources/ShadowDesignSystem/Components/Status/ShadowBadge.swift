import SwiftUI

nonisolated public enum ShadowBadgeIntent: Hashable, Sendable, CaseIterable {
  case neutral
  case info
  case success
  case warning
  case danger
  case accent

  public init(_ intent: ShadowIntent) {
    switch intent {
    case .neutral: self = .neutral
    case .info: self = .info
    case .success: self = .success
    case .warning: self = .warning
    case .danger: self = .danger
    }
  }

  var intent: ShadowIntent? {
    switch self {
    case .neutral: .neutral
    case .info: .info
    case .success: .success
    case .warning: .warning
    case .danger: .danger
    case .accent: nil
    }
  }

  var defaultSystemImage: String? {
    switch self {
    case .neutral, .accent: nil
    default: intent?.compactSystemImage
    }
  }

  var background: Color { intent?.background ?? ShadowColor.accent }
  var border: Color { intent?.border ?? ShadowColor.accent }
  var foreground: Color { intent?.foreground ?? ShadowColor.onAccent }
}

public struct ShadowBadge: View {
  private enum Content {
    case label(Text, ShadowBadgeIntent, String?)
    case count(ShadowBadgeCount)
    case dot(Text?)
  }

  private let content: Content

  public init(_ titleKey: LocalizedStringKey, intent: ShadowBadgeIntent = .neutral, systemImage: String? = nil) {
    content = .label(Text(titleKey), intent, systemImage ?? intent.defaultSystemImage)
  }

  public init(count: Int, maximum: Int = ShadowBadgeCount.defaultMaximum) {
    content = .count(ShadowBadgeCount(count, maximum: maximum))
  }

  public static func dot(_ accessibilityLabel: Text? = nil) -> ShadowBadge {
    ShadowBadge(content: .dot(accessibilityLabel))
  }

  private init(content: Content) {
    self.content = content
  }

  public var body: some View {
    switch content {
    case .label(let title, let intent, let systemImage): ShadowBadgeLabel(title: title, intent: intent, systemImage: systemImage)
    case .count(let count): ShadowBadgeCountView(count: count)
    case .dot(let label): ShadowBadgeDot(label: label)
    }
  }
}

private struct ShadowBadgeLabel: View {
  let title: Text
  let intent: ShadowBadgeIntent
  let systemImage: String?

  @Environment(\.isEnabled) private var isEnabled
  @ScaledMetric(relativeTo: .caption) private var height = ShadowDensity.current == .touch ? Spacing.space6 : Spacing.space5

  private var isTouch: Bool { ShadowDensity.current == .touch }

  var body: some View {
    HStack(spacing: Spacing.space1) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
          .fontWeight(.bold)
          .accessibilityHidden(true)
      }
      title.lineLimit(1)
    }
    .font(Font.shadow(.caption).weight(.semibold))
    .foregroundStyle(intent.foreground)
    .padding(.horizontal, isTouch ? Spacing.space2 + Spacing.space05 : Spacing.space2)
    .frame(minHeight: height)
    .background(intent.background, in: .capsule)
    .overlay { Capsule().strokeBorder(intent.border, lineWidth: intent == .accent ? 0 : 1) }
    .fixedSize()
    .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
  }
}

private struct ShadowBadgeCountView: View {
  let count: ShadowBadgeCount

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.locale) private var locale
  @ScaledMetric(relativeTo: .caption2) private var minimum = ShadowDensity.current == .touch ? Spacing.space5 : Spacing.space4

  var body: some View {
    if count.isVisible {
      Text(verbatim: count.text(locale: locale))
        .font(.system(.caption2, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(ShadowColor.dangerOnSolid)
        .padding(.horizontal, Spacing.space1 + Spacing.space05)
        .frame(minWidth: minimum, minHeight: minimum)
        .background(ShadowColor.dangerSolid, in: .capsule)
        .fixedSize()
        .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
        .accessibilityLabel(Text(count.value, format: .number))
    }
  }
}

private struct ShadowBadgeDot: View {
  let label: Text?

  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Circle()
      .fill(ShadowColor.dangerSolid)
      .frame(width: Spacing.space2 + Spacing.space05, height: Spacing.space2 + Spacing.space05)
      .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
      .accessibilityHidden(label == nil)
      .accessibilityLabel(label ?? Text(verbatim: ""))
  }
}

private struct ShadowBadgeOverlay: ViewModifier {
  let badge: ShadowBadge
  let isShown: Bool
  let value: Text?
  let ring: Color?

  private static let ringWidth: CGFloat = 2
  private let isTouch = ShadowDensity.current == .touch

  @ViewBuilder
  func body(content: Content) -> some View {
    let overlaid = content.overlay(alignment: .topTrailing) {
      if isShown {
        badge
          .padding(ring == nil ? 0 : Self.ringWidth)
          .background(ring ?? .clear, in: .capsule)
          .alignmentGuide(.top) { $0[VerticalAlignment.center] - (isTouch ? Spacing.space2 : Spacing.space1) }
          .alignmentGuide(.trailing) { $0[.leading] + (isTouch ? Spacing.space4 : Spacing.space2 + Spacing.space1) }
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    if isShown, let value {
      overlaid.accessibilityValue(value)
    } else {
      overlaid
    }
  }
}

extension View {
  public func shadowBadge(count: Int?, maximum: Int = ShadowBadgeCount.defaultMaximum, ring: Color? = nil) -> some View {
    let count = ShadowBadgeCount(count ?? 0, maximum: maximum)
    return modifier(
      ShadowBadgeOverlay(badge: ShadowBadge(count: count.value, maximum: count.maximum), isShown: count.isVisible, value: Text(count.value, format: .number), ring: ring))
  }

  public func shadowBadgeDot(_ isShown: Bool = true, label: Text? = nil, ring: Color? = nil) -> some View {
    modifier(ShadowBadgeOverlay(badge: .dot(), isShown: isShown, value: label, ring: ring))
  }
}
