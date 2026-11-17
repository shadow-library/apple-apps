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

  var fill: ShadowColorToken {
    guard self != .neutral else { return .bgHover }
    return intent?.backgroundToken ?? .accent
  }

  var border: ShadowColorToken {
    guard self != .neutral else { return .borderStrong }
    return intent?.borderToken ?? .accent
  }

  var foreground: ShadowColorToken { intent?.foregroundToken ?? .onAccent }
}

// On a prominent selection band the subtle intent fills sink into the accent, so the badge becomes an on-accent outline that keeps
// its symbol and word. Resolved at render time for the same reason as `ShadowProminenceStyle`.
nonisolated struct ShadowBadgeStyle: ShapeStyle {
  enum Role: Hashable, Sendable {
    case fill
    case border
    case foreground
  }

  let intent: ShadowBadgeIntent
  let role: Role

  static func isOnSelectionBand(prominence: BackgroundProminence, selectionIsAccentBand: Bool) -> Bool {
    prominence == .increased && selectionIsAccentBand
  }

  func token(isOnSelectionBand: Bool) -> ShadowColorToken? {
    switch (role, isOnSelectionBand) {
    case (.fill, true): nil
    case (_, true): .onAccent
    case (.fill, false): intent.fill
    case (.border, false): intent.border
    case (.foreground, false): intent.foreground
    }
  }

  func resolve(in environment: EnvironmentValues) -> Color {
    let isOnBand = Self.isOnSelectionBand(prominence: environment.shadowSelectionProminence, selectionIsAccentBand: environment.shadowSelectionIsAccentBand)
    return token(isOnSelectionBand: isOnBand)?.color ?? .clear
  }
}

nonisolated extension EnvironmentValues {
  // Touch lists select with an accent-soft fill (or no fill) yet still report `.increased`; only Mac lists and tables, and touch tables, use the accent band.
  #if os(macOS)
    @Entry var shadowSelectionIsAccentBand = true
  #else
    @Entry var shadowSelectionIsAccentBand = false
  #endif
}

public struct ShadowBadge: View {
  private enum Content {
    case label(Text, ShadowBadgeIntent, String?)
    case count(ShadowBadgeCount)
    case dot(Text?)
  }

  private let content: Content

  var title: Text? {
    guard case .label(let title, _, _) = content else { return nil }
    return title
  }

  public init(_ titleKey: LocalizedStringKey, intent: ShadowBadgeIntent = .neutral, systemImage: String? = nil) {
    content = .label(Text(titleKey), intent, systemImage ?? intent.defaultSystemImage)
  }

  public init(_ title: Text, intent: ShadowBadgeIntent = .neutral, systemImage: String? = nil) {
    content = .label(title, intent, systemImage ?? intent.defaultSystemImage)
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
      title.lineLimit(1).truncationMode(.tail)
    }
    .font(Font.shadow(.caption).weight(.semibold))
    .foregroundStyle(ShadowBadgeStyle(intent: intent, role: .foreground))
    .padding(.horizontal, isTouch ? Spacing.space2 + Spacing.space05 : Spacing.space2)
    .frame(minHeight: height)
    .background(ShadowBadgeStyle(intent: intent, role: .fill), in: .capsule)
    .overlay { Capsule().strokeBorder(ShadowBadgeStyle(intent: intent, role: .border), lineWidth: 1) }
    .shadowSkeletonShape(Capsule())
    .fixedSize(horizontal: false, vertical: true)
    .layoutPriority(1)
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

nonisolated struct ShadowBadgePlacement: Hashable, Sendable {
  let maximumOverlap: CGFloat

  init(density: ShadowDensity = .current) {
    maximumOverlap = density == .touch ? Spacing.space2 : Spacing.space1 + Spacing.space05
  }

  func anchor(in content: CGSize) -> CGPoint {
    let inset = min(content.width, content.height) * (1 - 1 / 2.squareRoot()) / 2
    return CGPoint(x: content.width - inset, y: inset)
  }

  func origin(for badge: CGSize, in content: CGSize) -> CGPoint {
    let anchor = anchor(in: content)
    return CGPoint(x: anchor.x - min(badge.height / 2, maximumOverlap), y: anchor.y - badge.height / 2)
  }
}

private struct ShadowBadgeLayout: Layout {
  let placement: ShadowBadgePlacement

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    subviews.first?.sizeThatFits(proposal) ?? .zero
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let content = subviews.first else { return }
    content.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    for badge in subviews.dropFirst() {
      let size = badge.sizeThatFits(.unspecified)
      let origin = placement.origin(for: size, in: bounds.size)
      badge.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(size))
    }
  }
}

private struct ShadowBadgeAccessibilityValue: ViewModifier {
  let value: Text?

  func body(content: Content) -> some View {
    content.accessibilityValue(value ?? Text(verbatim: ""), isEnabled: value != nil)
  }
}

private struct ShadowBadgeOverlay: ViewModifier {
  let badge: ShadowBadge
  let isShown: Bool
  let value: Text?
  let ring: Color?

  private static let ringWidth: CGFloat = 2

  func body(content: Content) -> some View {
    ShadowBadgeLayout(placement: ShadowBadgePlacement()) {
      content.modifier(ShadowBadgeAccessibilityValue(value: isShown ? value : nil))
      if isShown {
        badge
          .padding(ring == nil ? 0 : Self.ringWidth)
          .background(ring ?? .clear, in: .capsule)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
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
