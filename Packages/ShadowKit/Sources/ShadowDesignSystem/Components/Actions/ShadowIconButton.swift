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
    .shadowBadge(count: badgeCount)
    .dynamicTypeSize(...DynamicTypeSize.large)
    .accessibilityShowsLargeContentViewer()
    .help(title)
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
