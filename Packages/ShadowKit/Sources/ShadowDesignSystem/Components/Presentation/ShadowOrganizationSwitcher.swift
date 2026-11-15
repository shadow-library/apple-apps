import SwiftUI

nonisolated public struct ShadowOrganization: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let detail: String

  public init(id: String, name: String, detail: String) {
    self.id = id
    self.name = name
    self.detail = detail
  }

  public static func selected(_ id: ID, in organizations: [Self]) -> Self? {
    organizations.first { $0.id == id } ?? organizations.first
  }
}

public struct ShadowOrganizationSwitcher: View {
  private let title: LocalizedStringKey
  private let organizations: [ShadowOrganization]
  private let selection: Binding<ShadowOrganization.ID>

  public init(_ title: LocalizedStringKey, organizations: [ShadowOrganization], selection: Binding<ShadowOrganization.ID>) {
    self.title = title
    self.organizations = organizations
    self.selection = selection
  }

  public var body: some View {
    if let current = ShadowOrganization.selected(selection.wrappedValue, in: organizations) {
      Menu {
        Picker(title, selection: selection) {
          ForEach(organizations) { organization in Text(verbatim: organization.name).tag(organization.id) }
        }
      } label: {
        ShadowIdentityLabel(name: current.name, detail: current.detail, avatarName: current.name, avatarKind: .organization)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityLabel(Text(title))
      .accessibilityValue(Text(verbatim: "\(current.name), \(current.detail)"))
      .help(Text(title))
    }
  }
}
