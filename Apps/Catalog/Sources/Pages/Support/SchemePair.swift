import ShadowDesignSystem
import SwiftUI

struct SchemePair<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: Spacing.space3) { panels }
      VStack(alignment: .leading, spacing: Spacing.space3) { panels }
    }
  }

  @ViewBuilder
  private var panels: some View {
    panel("Light", scheme: .light)
    panel("Dark", scheme: .dark)
  }

  private func panel(_ title: LocalizedStringKey, scheme: ColorScheme) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text(title)
        .shadowFont(.caption)
        .foregroundStyle(ShadowColor.textTertiary)
      content
    }
    .padding(Spacing.space3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ShadowColor.surfaceCard, in: .rect(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous))
    .environment(\.colorScheme, scheme)
  }
}
