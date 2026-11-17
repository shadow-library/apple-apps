import SwiftUI

nonisolated public enum ShadowContentUnavailableKind: Hashable, Sendable, CaseIterable {
  case empty
  case error
  case noResults
  case accessDenied

  public var systemImage: String {
    switch self {
    case .empty: "target"
    case .error: "exclamationmark.triangle"
    case .noResults: "magnifyingglass"
    case .accessDenied: "lock"
    }
  }
}

public struct ShadowContentUnavailable<Actions: View>: View {
  let title: Text
  let message: Text?
  private let systemImage: String
  private let actions: Actions

  public init(
    _ titleKey: LocalizedStringKey,
    kind: ShadowContentUnavailableKind = .empty,
    systemImage: String? = nil,
    message: LocalizedStringKey? = nil,
    @ViewBuilder actions: () -> Actions
  ) {
    self.init(Text(titleKey), kind: kind, systemImage: systemImage, message: message.map { Text($0) }, actions: actions)
  }

  public init(_ title: Text, kind: ShadowContentUnavailableKind = .empty, systemImage: String? = nil, message: Text? = nil, @ViewBuilder actions: () -> Actions) {
    self.title = title
    self.message = message
    self.systemImage = systemImage ?? kind.systemImage
    self.actions = actions()
  }

  public var body: some View {
    ContentUnavailableView {
      Label {
        title.shadowFont(.title3)
      } icon: {
        Image(systemName: systemImage)
          .foregroundStyle(ShadowColor.textTertiary)
      }
      .foregroundStyle(ShadowColor.textPrimary)
    } description: {
      if let message {
        message
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    } actions: {
      actions.buttonStyle(.shadowFilled)
    }
  }
}

extension ShadowContentUnavailable where Actions == EmptyView {
  public init(_ titleKey: LocalizedStringKey, kind: ShadowContentUnavailableKind = .empty, systemImage: String? = nil, message: LocalizedStringKey? = nil) {
    self.init(titleKey, kind: kind, systemImage: systemImage, message: message) { EmptyView() }
  }

  public init(_ title: Text, kind: ShadowContentUnavailableKind = .empty, systemImage: String? = nil, message: Text? = nil) {
    self.init(title, kind: kind, systemImage: systemImage, message: message) { EmptyView() }
  }
}
