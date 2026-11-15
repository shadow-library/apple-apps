import SwiftUI

nonisolated public enum ShadowAccountMenuLabelStyle: Hashable, Sendable, CaseIterable {
  case avatar
  case avatarAndName
}

public enum ShadowAccountMenuAvatar: Sendable {
  case initials
  case image(Image)

  var source: ShadowAvatarSource {
    switch self {
    case .initials: .initials
    case .image(let image): .image(image)
    }
  }
}

public struct ShadowAccountMenu<Content: View>: View {
  private let title: LocalizedStringKey
  private let name: String
  private let email: String
  private let avatar: ShadowAccountMenuAvatar
  private let labelStyle: ShadowAccountMenuLabelStyle
  private let signOutTitle: LocalizedStringKey
  private let onAccount: () -> Void
  private let onSignOut: () -> Void
  private let content: Content

  @Environment(\.displayScale) private var displayScale
  @Environment(\.colorScheme) private var colorScheme

  public init(
    _ title: LocalizedStringKey,
    name: String,
    email: String,
    avatar: ShadowAccountMenuAvatar = .initials,
    labelStyle: ShadowAccountMenuLabelStyle = .avatar,
    signOutTitle: LocalizedStringKey,
    onAccount: @escaping () -> Void,
    onSignOut: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.name = name
    self.email = email
    self.avatar = avatar
    self.labelStyle = labelStyle
    self.signOutTitle = signOutTitle
    self.onAccount = onAccount
    self.onSignOut = onSignOut
    self.content = content()
  }

  public var body: some View {
    let menu = Menu {
      Section {
        Button(action: onAccount) {
          Label {
            Text(verbatim: name)
            Text(verbatim: email)
          } icon: {
            headerIcon
          }
        }
      }
      content
      Section {
        Button(signOutTitle, systemImage: "xmark.circle", action: onSignOut)
      }
    } label: {
      label
    }
    .menuIndicator(.hidden)
    .accessibilityLabel(Text(title))
    .accessibilityValue(Text(verbatim: name))
    .help(Text(title))

    switch labelStyle {
    case .avatar: menu
    case .avatarAndName: menu.menuStyle(.button).buttonStyle(.plain)
    }
  }

  @ViewBuilder
  private var label: some View {
    switch labelStyle {
    case .avatar:
      ShadowAvatar(name: name, size: ShadowDensity.current == .touch ? .small : .extraSmall, source: avatar.source)
    case .avatarAndName:
      HStack(spacing: Spacing.space3) {
        ShadowAvatar(name: name, size: ShadowDensity.current == .touch ? .medium : .small, source: avatar.source)
        VStack(alignment: .leading, spacing: 0) {
          Text(verbatim: name)
            .shadowFont(.headline)
            .foregroundStyle(ShadowColor.textPrimary)
          Text(verbatim: email)
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.up.chevron.down")
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
          .accessibilityHidden(true)
      }
      .contentShape(.rect)
    }
  }

  private var headerIcon: Image {
    let renderer = ImageRenderer(
      content: ShadowAvatar(name: name, size: ShadowDensity.current == .touch ? .small : .extraSmall, source: avatar.source)
        .environment(\.colorScheme, colorScheme)
    )
    renderer.scale = displayScale
    #if os(macOS)
      if let image = renderer.nsImage { return Image(nsImage: image) }
    #else
      if let image = renderer.uiImage { return Image(uiImage: image.withRenderingMode(.alwaysOriginal)) }
    #endif
    return Image(systemName: "person.crop.circle")
  }
}
