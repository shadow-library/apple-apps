import SwiftUI

nonisolated public enum ShadowSidebarBadge: Hashable, Sendable {
  case count(Int)
  case alert(Int)

  var count: Int? {
    guard case .count(let value) = self, value > 0 else { return nil }
    return value
  }

  var alertCount: Int? {
    guard case .alert(let value) = self, value > 0 else { return nil }
    return value
  }
}

public struct ShadowSidebarLabel: View {
  private let title: Text
  private let systemImage: String
  private let badge: ShadowSidebarBadge?
  @Environment(\.backgroundProminence) private var backgroundProminence

  public init(_ title: Text, systemImage: String, badge: ShadowSidebarBadge? = nil) {
    self.title = title
    self.systemImage = systemImage
    self.badge = badge
  }

  public init(_ titleKey: LocalizedStringKey, systemImage: String, badge: ShadowSidebarBadge? = nil) {
    self.init(Text(titleKey), systemImage: systemImage, badge: badge)
  }

  public var body: some View {
    Label {
      HStack(spacing: Spacing.space2) {
        title.frame(maxWidth: .infinity, alignment: .leading)
        if let alert = badge?.alertCount { ShadowBadge(count: alert) }
      }
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(backgroundProminence == .increased ? ShadowColor.onAccent : ShadowColor.accentText)
    }
    .badge(badge?.count ?? 0)
  }
}

public struct ShadowSidebarHeader: View {
  private let title: Text

  public init(_ title: Text) {
    self.title = title
  }

  public init(_ titleKey: LocalizedStringKey) {
    self.init(Text(titleKey))
  }

  public var body: some View {
    title
      .shadowFont(ShadowDensity.current == .touch ? .footnote : .sectionHeader)
      .foregroundStyle(ShadowDensity.current == .touch ? ShadowColor.textTertiary : ShadowColor.textSecondary)
      .textCase(nil)
      .accessibilityAddTraits(.isHeader)
  }
}
