import ShadowDesignSystem
import SwiftUI

extension EnvironmentValues {
  @Entry var catalogScrollFraction: Double?
}

extension View {
  func catalogScrollAnchor() -> some View { modifier(CatalogScrollAnchor()) }
}

private struct CatalogScrollAnchor: ViewModifier {
  @Environment(\.catalogScrollFraction) private var fraction
  @State private var position = ScrollPosition()

  func body(content: Content) -> some View {
    if let fraction {
      content
        .scrollPosition($position)
        .onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
          let insets = geometry.contentInsets
          let lowerBound = -insets.top
          return lowerBound...max(lowerBound, geometry.contentSize.height + insets.bottom - geometry.containerSize.height)
        } action: { _, offsets in
          position.scrollTo(y: offsets.lowerBound + (offsets.upperBound - offsets.lowerBound) * fraction)
        }
    } else {
      content
    }
  }
}

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
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .catalogScrollAnchor()
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
