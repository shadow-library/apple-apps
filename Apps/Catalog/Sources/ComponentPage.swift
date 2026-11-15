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

extension View {
  func catalogListPage(_ component: CatalogComponent, anchors: [String]) -> some View {
    modifier(CatalogListAnchor(anchors: anchors))
      .background(ShadowColor.surfaceApp)
      .accessibilityIdentifier("component-\(component.id)")
  }
}

private struct CatalogListAnchor: ViewModifier {
  let anchors: [String]
  @Environment(\.catalogScrollFraction) private var fraction
  @State private var position = ScrollPosition()

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .scrollPosition($position)
        .task {
          guard let last = anchors.indices.last else { return }
          guard let fraction, fraction > 0 else { return }
          let index = min(last, Int((fraction * Double(last)).rounded()))
          for delay in [0.4, 1.2] {
            try? await Task.sleep(for: .seconds(delay))
            if fraction >= 1 {
              proxy.scrollTo(CatalogListEnd.id, anchor: .bottom)
              position.scrollTo(edge: .bottom)
            } else {
              proxy.scrollTo(anchors[index], anchor: .top)
            }
          }
        }
    }
  }
}

struct CatalogListEnd: View {
  static let id = "catalog-list-end"

  var body: some View {
    Color.clear
      .frame(height: 1)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .accessibilityHidden(true)
      .id(Self.id)
  }
}

struct StateListSection<Content: View>: View {
  let title: String
  let note: LocalizedStringKey?
  @ViewBuilder let content: Content

  init(_ title: String, note: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.note = note
    self.content = content()
  }

  var body: some View {
    #if os(macOS)
      Section {
        content
      } header: {
        VStack(alignment: .leading, spacing: Spacing.space05) {
          ShadowSectionHeader(LocalizedStringKey(title))
          if let note { noteText(note) }
        }
      }
      .listSectionSeparator(.hidden)
      .id(title)
    #else
      Section {
        content
      } header: {
        ShadowSectionHeader(LocalizedStringKey(title))
      } footer: {
        if let note { noteText(note) }
      }
      .id(title)
    #endif
  }

  private func noteText(_ note: LocalizedStringKey) -> some View {
    Text(note)
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct ComponentPage<Content: View>: View {
  let component: CatalogComponent
  @ViewBuilder let content: Content

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  private var margin: CGFloat {
    #if os(iOS)
      horizontalSizeClass == .compact ? Spacing.space4 : Spacing.space5
    #else
      Spacing.space5
    #endif
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space8) {
        content
      }
      .frame(maxWidth: ShadowMetrics.readableWidth, alignment: .leading)
      .padding(.horizontal, margin)
      .padding(.vertical, Spacing.space4)
      .frame(maxWidth: .infinity)
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

extension EnvironmentValues {
  @Entry var catalogTakesSnapshot = false
  @Entry var catalogIsAutomated = false
}

extension View {
  func catalogDemoLocale() -> some View { modifier(CatalogDemoLocale()) }
}

private struct CatalogDemoLocale: ViewModifier {
  static let locale = Locale(identifier: "en_GB")

  @Environment(\.catalogIsAutomated) private var isAutomated

  func body(content: Content) -> some View {
    if isAutomated {
      content.environment(\.locale, Self.locale)
    } else {
      content
    }
  }
}

extension View {
  func catalogSnapshotFocus() -> some View { modifier(CatalogSnapshotFocus()) }
}

private struct CatalogSnapshotFocus: ViewModifier {
  @Environment(\.catalogTakesSnapshot) private var takesSnapshot
  @FocusState private var isFocused: Bool

  func body(content: Content) -> some View {
    #if os(macOS)
      content
        .focused($isFocused)
        .task {
          guard takesSnapshot else { return }
          try? await Task.sleep(for: .milliseconds(300))
          isFocused = true
        }
    #else
      content
    #endif
  }
}
