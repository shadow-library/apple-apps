import SwiftUI

nonisolated public enum ShadowListKind: Hashable, Sendable, CaseIterable {
  case grouped
  case plain
  case sidebar
}

public struct ShadowSectionHeader: View {
  private let title: Text

  public init(_ title: Text) {
    self.title = title
  }

  public init(_ titleKey: LocalizedStringKey) {
    self.init(Text(titleKey))
  }

  public var body: some View {
    title
      .shadowFont(.subheadline)
      .fontWeight(.semibold)
      .foregroundStyle(ShadowColor.textSecondary)
      .textCase(nil)
      .accessibilityAddTraits(.isHeader)
  }
}

private struct ShadowListStyleModifier: ViewModifier {
  let kind: ShadowListKind

  func body(content: Content) -> some View {
    base(content)
      .environment(\.defaultMinListRowHeight, ShadowMetrics.rowHeight)
      .environment(\.shadowMaterialLayer, .content)
      .listRowSeparatorTint(ShadowColor.borderDefault)
      .listSectionSeparatorTint(ShadowColor.borderDefault)
  }

  @ViewBuilder
  private func base(_ content: Content) -> some View {
    switch kind {
    case .grouped:
      #if os(macOS)
        content
          .listStyle(.inset(alternatesRowBackgrounds: false))
          .scrollContentBackground(.hidden)
          .background(ShadowColor.surfaceCard)
      #else
        content
          .listStyle(.insetGrouped)
          .scrollContentBackground(.hidden)
          .background(ShadowColor.surfaceApp)
      #endif
    case .plain:
      content
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ShadowColor.surfaceCard)
    case .sidebar:
      content.listStyle(.sidebar)
    }
  }
}

extension View {
  public func shadowListStyle(_ kind: ShadowListKind = .grouped) -> some View {
    modifier(ShadowListStyleModifier(kind: kind))
  }

  /// Re-applies `ShadowListRow` insets and chrome on a wrapper (a `Button` or `NavigationLink`), because List reads row modifiers only from the outermost row view.
  public func shadowListRowChrome() -> some View {
    shadowListRowChrome(background: ShadowColor.surfaceCard)
  }

  func shadowListRowChrome(background: (some View)?) -> some View {
    listRowInsets(ShadowListMetrics().rowInsets)
      .listRowBackground(background)
      .listRowSeparatorTint(ShadowColor.borderDefault)
  }
}
