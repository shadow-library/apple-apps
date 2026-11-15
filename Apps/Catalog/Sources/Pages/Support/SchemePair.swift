import ShadowDesignSystem
import SwiftUI

struct SchemePair<Content: View>: View {
  enum Surface { case card, app }

  var surface = Surface.card
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
    .background(surface == .app ? ShadowColor.surfaceApp : ShadowColor.surfaceCard, in: .rect(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous))
    .overlay {
      if surface == .app {
        RoundedRectangle(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous).strokeBorder(ShadowColor.borderSubtle)
      }
    }
    .environment(\.colorScheme, scheme)
  }
}
