import ShadowDesignSystem
import SwiftUI

struct AccountMenuPage: View {
  var body: some View {
    ComponentPage(component: .accountMenu) {
      StateSection(
        "Open menu",
        note:
          "The native menu opens in its own window, which screenshots can’t capture; this panel mirrors it. Name and email confirm the account; Sign out comes last in its own section."
      ) {
        StaticIllustration {
          PresentationBackdrop(height: ShadowDensity.current == .touch ? 400 : 260, alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: Spacing.space2) {
              DemoAccountMenu(labelStyle: .avatar, inGlassCircle: true)
              StaticMenuPanel(items: Self.items(isTouch: ShadowDensity.current == .touch), width: ShadowDensity.current == .touch ? 320 : 300) {
                AccountMenuHeader()
              }
            }
          }
        }
      }
      StateSection("Toolbar avatar", note: "iPhone and iPad: an avatar in a glass circle at the trailing end of the root toolbar. Mac: a small avatar in the toolbar.") {
        PresentationBackdrop(height: 120, alignment: .topTrailing) {
          DemoAccountMenu(labelStyle: .avatar, inGlassCircle: true)
        }
      }
      StateSection("Sidebar footer", note: "Avatar and name open the same menu from the bottom of a sidebar.") {
        DemoAccountMenu(labelStyle: .avatarAndName)
          .frame(maxWidth: 300)
          .shadowCard()
      }
      StateSection("Photo avatar", note: "A profile photo replaces the initials everywhere, including the menu header.") {
        DemoAccountMenu(name: "Mira Vale", email: "mira@shadowlibrary.app", avatar: .image(SamplePortrait.image(ShadowColor.chart5)), labelStyle: .avatarAndName)
          .frame(maxWidth: 300)
          .shadowCard()
      }
      StateSection("Long name and email", note: "Both lines truncate in the button; the menu header shows them in full.") {
        DemoAccountMenu(name: "Maximiliana Archibald-Montgomery", email: "maximiliana.archibald-montgomery@shadowlibrary.app", labelStyle: .avatarAndName)
          .frame(maxWidth: 300)
          .shadowCard()
      }
    }
  }

  private static func items(isTouch: Bool) -> [StaticMenuItem] {
    [
      .separator("header"),
      .action("Account and security…", systemImage: "shield", shortcut: isTouch ? nil : KeyboardShortcut(",", modifiers: .command)),
      .action("Switch organization", systemImage: "person.2", isHighlighted: !isTouch),
      .action("Appearance", systemImage: "moon"),
      .separator("sign-out"),
      .action("Sign out", systemImage: "xmark.circle"),
    ]
  }
}

private struct AccountMenuHeader: View {
  var body: some View {
    HStack(spacing: Spacing.space3) {
      ShadowAvatar(name: DemoAccount.name, size: ShadowDensity.current == .touch ? .medium : .small)
      VStack(alignment: .leading, spacing: 0) {
        Text(verbatim: DemoAccount.name)
          .shadowFont(.headline)
          .foregroundStyle(ShadowColor.textPrimary)
        Text(verbatim: DemoAccount.email)
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
      }
      .lineLimit(1)
    }
    .padding(.horizontal, ShadowDensity.current == .touch ? Spacing.space4 : Spacing.space2)
    .padding(.vertical, Spacing.space2)
  }
}

enum DemoAccount {
  static let name = "Ada Lovelace"
  static let email = "ada@shadowlibrary.app"
  static let organizations = ["Shadow Library · Novel Forge", "Shadow Library · Memoir", "Synapse Labs"]
}

struct DemoAccountMenu: View {
  var name = DemoAccount.name
  var email = DemoAccount.email
  var avatar: ShadowAccountMenuAvatar = .initials
  var labelStyle: ShadowAccountMenuLabelStyle = .avatar
  var inGlassCircle = false

  @State private var organization = DemoAccount.organizations[0]
  @State private var appearance = CatalogAppearance.system

  var body: some View {
    if inGlassCircle {
      menu
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(width: ShadowMetrics.control(.medium), height: ShadowMetrics.control(.medium))
        .shadowGlass(.regular.interactive(), in: Circle())
    } else {
      menu
    }
  }

  private var menu: some View {
    ShadowAccountMenu(
      "Account", name: name, email: email, avatar: avatar, labelStyle: labelStyle, signOutTitle: "Sign out", onAccount: {}, onSignOut: {},
      content: {
        Section {
          Button("Account and security…", systemImage: "shield") {}
            .keyboardShortcut(",", modifiers: .command)
          Picker(selection: $organization) {
            ForEach(DemoAccount.organizations, id: \.self) { organization in Text(verbatim: organization).tag(organization) }
          } label: {
            Label("Switch organization", systemImage: "person.2")
          }
          .pickerStyle(.menu)
          Picker(selection: $appearance) {
            ForEach(CatalogAppearance.allCases) { option in Label(option.title, systemImage: option.systemImage).tag(option) }
          } label: {
            Label("Appearance", systemImage: "moon")
          }
          .pickerStyle(.menu)
        }
      })
  }
}
