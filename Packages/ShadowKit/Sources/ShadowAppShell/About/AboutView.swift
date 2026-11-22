import ShadowDesignSystem
import SwiftUI

extension SettingsTabs.Tab {
  public static let about = SettingsTabs.Tab("about")
}

/// The app's name and version, what leaves the device, its privacy policy, support and contact when the identity sets them, and the third-party notices.
/// Shown inside the app's own navigation stack, which the acknowledgements are pushed onto.
public struct AboutView: View {
  private let identity: AppIdentity
  private let disclosures: [AboutDisclosure]
  private let version: AppVersion
  private let links: [AboutLink]

  public init(identity: AppIdentity, disclosures: [AboutDisclosure], version: AppVersion = AppVersion()) {
    self.identity = identity
    self.disclosures = disclosures
    self.version = version
    links = AboutLink.links(for: identity, version: version)
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        header
        if !disclosures.isEmpty { disclosuresSection }
        if !links.isEmpty { linksSection }
        if let acknowledgements = Acknowledgements.bundled { acknowledgementsSection(acknowledgements) }
      }
      .padding(Spacing.space4)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .shadowScreen(.pushed)
    .navigationTitle(Text("About \(identity.displayName)", tableName: "About", bundle: .module))
    .environment(\.appIdentity, identity)
  }

  private var header: some View {
    VStack(spacing: Spacing.space1) {
      Text(verbatim: identity.displayName).shadowFont(.title)
      Text(version.label).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
    }
    .frame(maxWidth: .infinity)
  }

  private var disclosuresSection: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        ForEach(disclosures) { disclosure in
          Label {
            Text(disclosure.text).fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: disclosure.systemImage).foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("What leaves this device", tableName: "About", bundle: .module).shadowFont(.headline)
    }
  }

  private var linksSection: some View {
    ShadowGroupedSection {
      ForEach(links) { link in
        Link(destination: link.url) {
          ShadowListRow(title: title(of: link)) {
            Image(systemName: systemImage(of: link)).foregroundStyle(ShadowColor.textSecondary)
          } trailing: {
            Image(systemName: "arrow.up.right").foregroundStyle(ShadowColor.textTertiary).accessibilityHidden(true)
          }
        }
        .buttonStyle(.shadowRow)
      }
    } header: {
      Text("Privacy and support", tableName: "About", bundle: .module).shadowFont(.headline)
    }
  }

  private func acknowledgementsSection(_ acknowledgements: Acknowledgements) -> some View {
    ShadowGroupedSection {
      NavigationLink {
        AcknowledgementsView(acknowledgements: acknowledgements)
      } label: {
        ShadowListRow(title: Text("Acknowledgements", tableName: "About", bundle: .module), accessory: .chevron) {
          Image(systemName: "doc.text").foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .buttonStyle(.shadowRow)
    } footer: {
      Text("The notices of the third-party work \(identity.displayName) includes.", tableName: "About", bundle: .module)
    }
  }

  private func title(of link: AboutLink) -> Text {
    switch link {
    case .privacyPolicy: Text("Privacy Policy", tableName: "About", bundle: .module)
    case .support: Text("Support", tableName: "About", bundle: .module)
    case .contact: Text("Contact", tableName: "About", bundle: .module)
    }
  }

  private func systemImage(of link: AboutLink) -> String {
    switch link {
    case .privacyPolicy: "hand.raised"
    case .support: "questionmark.circle"
    case .contact: "envelope"
    }
  }
}

/// The row or tab label that opens `AboutView`: "About <app>".
public struct AboutLabel: View {
  private let identity: AppIdentity

  public init(identity: AppIdentity) {
    self.identity = identity
  }

  public var body: some View {
    Label {
      Text("About \(identity.displayName)", tableName: "About", bundle: .module)
    } icon: {
      Image(systemName: "info.circle")
    }
  }
}

#Preview("Every row") {
  NavigationStack {
    AboutView(
      identity: AppIdentity(
        id: "com.shadow.apps.preview", displayName: "Preview", vaultNoun: "library", vaultTitle: "Library", exampleBucketName: "my-preview",
        privacyPolicyURL: URL(string: "https://example.com/privacy"), supportURL: URL(string: "https://example.com/support"), contactAddress: "help@example.com"),
      disclosures: [.modelProvider(app: .preview), .sync(app: .preview), .keychain(app: .preview), .nothingElse(app: .preview)], version: AppVersion(version: "1.0", build: "42"))
  }
  .shadowTheme()
}

#Preview("Nothing set") {
  NavigationStack {
    AboutView(identity: .preview, disclosures: [.nothingElse(app: .preview)], version: AppVersion(version: "1.0", build: nil))
  }
  .shadowTheme()
}

extension AppIdentity {
  fileprivate static let preview = AppIdentity(id: "com.shadow.apps.preview", displayName: "Preview", vaultNoun: "library", vaultTitle: "Library", exampleBucketName: "my-preview")
}
