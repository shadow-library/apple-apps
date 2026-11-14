import SwiftUI

public struct ShadowRowLabel: View {
  private let title: Text
  private let subtitle: Text?

  public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
    self.title = Text(title)
    self.subtitle = subtitle.map { Text($0) }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space05) {
      title
        .shadowFont(.body)
        .foregroundStyle(ShadowColor.textPrimary)
      if let subtitle {
        subtitle
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
