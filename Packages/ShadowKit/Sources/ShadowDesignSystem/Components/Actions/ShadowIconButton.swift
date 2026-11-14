import SwiftUI

public struct ShadowIconButton: View {
  private let title: Text
  private let systemImage: String
  private let variant: ShadowButtonVariant
  private let role: ButtonRole?
  private let badgeCount: Int?
  private let action: () -> Void

  public init(
    _ titleKey: LocalizedStringKey,
    systemImage: String,
    variant: ShadowButtonVariant = .plain,
    role: ButtonRole? = nil,
    badgeCount: Int? = nil,
    action: @escaping () -> Void
  ) {
    title = Text(titleKey)
    self.systemImage = systemImage
    self.variant = variant
    self.role = role
    self.badgeCount = badgeCount
    self.action = action
  }

  public var body: some View {
    Button(role: role, action: action) {
      Label {
        title
      } icon: {
        Image(systemName: systemImage)
      }
    }
    .buttonStyle(ShadowButtonStyle(variant, layout: .icon))
    .dynamicTypeSize(...DynamicTypeSize.large)
    .accessibilityShowsLargeContentViewer()
    .help(title)
    .overlay(alignment: .topTrailing) {
      if let badgeCount, badgeCount > 0 { ShadowIconButtonBadge(count: badgeCount) }
    }
    .modifier(BadgeValueModifier(count: badgeCount))
  }
}

private struct BadgeValueModifier: ViewModifier {
  let count: Int?

  func body(content: Content) -> some View {
    if let count, count > 0 {
      content.accessibilityValue(Text(count, format: .number))
    } else {
      content
    }
  }
}

private struct ShadowIconButtonBadge: View {
  static let maximumShown = 99
  let count: Int
  private let isTouch = ShadowDensity.current == .touch
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Group {
      if count > Self.maximumShown {
        Text("\(Self.maximumShown)+")
      } else {
        Text(count, format: .number)
      }
    }
    .font(.system(.caption2, weight: .semibold))
    .monospacedDigit()
    .foregroundStyle(ShadowColor.dangerOnSolid)
    .padding(.horizontal, Spacing.space1)
    .frame(minWidth: isTouch ? Spacing.space5 : Spacing.space4, minHeight: isTouch ? Spacing.space5 : Spacing.space4)
    .background(ShadowColor.dangerSolid, in: .capsule)
    .fixedSize()
    .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
    .alignmentGuide(.top) { $0[VerticalAlignment.center] - (isTouch ? Spacing.space2 : 0) }
    .alignmentGuide(.trailing) { $0[.leading] + (isTouch ? Spacing.space4 : Spacing.space2) }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// A glass capsule for floating chrome; toolbar groups get their capsule from the system and must not use this.
public struct ShadowIconButtonGroup<Content: View>: View {
  private let glass: ShadowGlass
  private let content: Content

  public init(_ glass: ShadowGlass = .regular, @ViewBuilder content: () -> Content) {
    self.glass = glass
    self.content = content()
  }

  public var body: some View {
    HStack(spacing: 0) { content }
      .padding(.horizontal, ShadowDensity.current == .touch ? Spacing.space1 : Spacing.space05)
      .shadowGlass(glass, in: Capsule(style: .continuous))
  }
}
