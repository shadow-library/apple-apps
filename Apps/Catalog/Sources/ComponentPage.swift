import ShadowDesignSystem
import SwiftUI

struct ComponentPage<Content: View>: View {
  let component: CatalogComponent
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space8) {
        content
      }
      .frame(maxWidth: ShadowMetrics.readableWidth, alignment: .leading)
      .padding(Spacing.space4)
      .frame(maxWidth: .infinity)
    }
    .background(ShadowColor.surfaceApp)
    .accessibilityIdentifier("component-\(component.id)")
  }
}

struct StateSection<Content: View>: View {
  let title: LocalizedStringKey
  let note: LocalizedStringKey?
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey, note: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.note = note
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      VStack(alignment: .leading, spacing: Spacing.space05) {
        Text(title)
          .shadowFont(.headline)
          .foregroundStyle(ShadowColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        if let note {
          Text(note)
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
